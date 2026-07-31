# frozen_string_literal: true

require "test_helper"

class WatchedFolderScanServiceTest < ActiveSupport::TestCase
  setup do
    @watched = Dir.mktmpdir("watched")
    @ebook_dest = Dir.mktmpdir("wf-ebooks")
    @audiobook_dest = Dir.mktmpdir("wf-audiobooks")

    set_setting("ebook_output_path", @ebook_dest, "string", "paths")
    set_setting("audiobook_output_path", @audiobook_dest, "string", "paths")
    set_setting("library_import_enabled", "true", "boolean", "import")
    set_setting("library_import_path", @watched, "string", "import")
    Setting.where(key: "audiobookshelf_url").destroy_all

    # A loose ebook file and an audiobook folder, mirroring a completed-download
    # layout.
    File.write(File.join(@watched, "Brandon Sanderson - Mistborn.epub"), "dummy epub")
    audiobook_dir = File.join(@watched, "Brandon Sanderson - Elantris")
    FileUtils.mkdir_p(audiobook_dir)
    File.write(File.join(audiobook_dir, "track01.mp3"), "dummy audio")
  end

  teardown do
    [ @watched, @ebook_dest, @audiobook_dest ].each { |dir| FileUtils.rm_rf(dir) if dir }
  end

  test "detects an ebook file and an audiobook folder" do
    result = MetadataService.stub(:search, []) do
      assert_difference "DetectedImport.count", 2 do
        WatchedFolderScanService.scan!
      end
    end

    assert_equal 2, result.detected

    canonical = File.realpath(@watched)

    ebook = DetectedImport.find_by(book_type: "ebook")
    assert_equal File.join(canonical, "Brandon Sanderson - Mistborn.epub"), ebook.source_path
    assert_equal "Mistborn", ebook.parsed_title

    audiobook = DetectedImport.find_by(book_type: "audiobook")
    assert_equal File.join(canonical, "Brandon Sanderson - Elantris"), audiobook.source_path
  end

  test "splits a collection folder into one audiobook per titled subfolder" do
    collection = File.join(@watched, "Tolkien Audiobook Collection")
    {
      "01 The Hobbit" => 3,
      "02 The Fellowship Of The Ring" => 4,
      "03 The Two Towers" => 2
    }.each do |title, tracks|
      dir = File.join(collection, title)
      FileUtils.mkdir_p(dir)
      tracks.times { |i| File.write(File.join(dir, format("%<title>s - %<n>02d.mp3", title: title, n: i + 1)), "dummy audio") }
    end

    MetadataService.stub(:search, []) do
      WatchedFolderScanService.scan!
    end

    canonical = File.realpath(@watched)
    subfolders = [ "01 The Hobbit", "02 The Fellowship Of The Ring", "03 The Two Towers" ]

    # One audiobook per titled subfolder, none for the collection root itself.
    subfolders.each do |title|
      path = File.join(canonical, "Tolkien Audiobook Collection", title)
      assert DetectedImport.exists?(source_path: path, book_type: "audiobook"),
        "expected a detection for #{title}"
    end
    assert_not DetectedImport.exists?(source_path: File.join(canonical, "Tolkien Audiobook Collection")),
      "the collection root must not be detected as a single audiobook"
  end

  test "keeps a multi-disc audiobook folder as a single import" do
    book = File.join(@watched, "Some Long Book")
    [ "CD1", "CD2", "Disc 3" ].each do |disc|
      dir = File.join(book, disc)
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, "track01.mp3"), "dummy audio")
    end

    MetadataService.stub(:search, []) do
      WatchedFolderScanService.scan!
    end

    canonical = File.realpath(@watched)
    assert DetectedImport.exists?(source_path: File.join(canonical, "Some Long Book"), book_type: "audiobook"),
      "the whole multi-disc folder should be one audiobook"
    assert_not DetectedImport.exists?(source_path: File.join(canonical, "Some Long Book", "CD1")),
      "disc subfolders must not become separate audiobooks"
  end

  test "does not re-detect known files on a second scan" do
    MetadataService.stub(:search, []) do
      WatchedFolderScanService.scan!

      assert_no_difference "DetectedImport.count" do
        result = WatchedFolderScanService.scan!
        assert_equal 0, result.detected
      end
    end
  end

  test "a new file that reuses a consumed inode is detected, not swallowed by the stale claim" do
    MetadataService.stub(:search, []) do
      WatchedFolderScanService.scan!
      consumed = DetectedImport.find_by(book_type: "ebook")
      # Stand in for a move import: the detection keeps the identity of a source
      # that no longer exists, and the filesystem hands the pair to a new file.
      File.delete(consumed.source_path)
      replacement = File.join(File.realpath(@watched), "Brandon Sanderson - Warbreaker.epub")
      File.write(replacement, "dummy epub")
      stat = File.lstat(replacement)
      consumed.update_columns(source_device: stat.dev, source_inode: stat.ino)

      assert_difference "DetectedImport.count", 1 do
        WatchedFolderScanService.scan!
      end

      consumed.reload
      assert_nil consumed.source_inode, "the stale claim is released so the index is free"
      assert DetectedImport.exists?(source_path: replacement)
    end
  end

  test "a hardlinked second path to a live source stays known" do
    MetadataService.stub(:search, []) do
      WatchedFolderScanService.scan!
      known = DetectedImport.find_by(book_type: "ebook")
      File.link(known.source_path, File.join(@watched, "Mistborn (hardlink).epub"))

      assert_no_difference "DetectedImport.count" do
        WatchedFolderScanService.scan!
      end
      assert_equal known.source_inode, known.reload.source_inode
    end
  end

  test "metadata_path_for points at the audio file inside an audiobook folder" do
    release = File.join(@watched, "Brandon Sanderson - Elantris")

    assert_equal File.join(release, "track01.mp3"), WatchedFolderScanService.metadata_path_for(release)
  end

  test "metadata_path_for returns a single file unchanged" do
    ebook = File.join(@watched, "Brandon Sanderson - Mistborn.epub")

    assert_equal ebook, WatchedFolderScanService.metadata_path_for(ebook)
  end

  test "returns nil when scanning is disabled" do
    set_setting("library_import_enabled", "false", "boolean", "import")
    assert_nil WatchedFolderScanService.scan!
  end

  test "refuses a watched path that overlaps an output path" do
    set_setting("library_import_path", @ebook_dest, "string", "import")
    assert_nil WatchedFolderScanService.scan!
  end

  private

  def set_setting(key, value, type, category)
    Setting.find_or_create_by(key: key).update!(
      value: value, value_type: type, category: category
    )
  end
end
