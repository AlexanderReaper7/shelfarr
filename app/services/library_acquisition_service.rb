# frozen_string_literal: true

# Shared "identify a book and import a source file into the organised library"
# engine used by any front door that adopts a file which was not acquired
# through a Shelfarr request (currently the watched-folder importer).
#
# The request pipeline still uses UploadProcessingJob / PostProcessingJob
# directly; this service reuses the same underlying identification and
# path-template services so both paths agree on structure and matching.
#
# +identify+ is read-only: it inspects a source file and returns a ranked
# suggestion without creating any Book or touching the filesystem beyond
# reading embedded metadata. +import!+ (see below) performs the actual,
# crash-safe publication once an admin has approved a target Book.
class LibraryAcquisitionService
  # Audio container extensions that mark a file (or the folder containing it) as
  # an audiobook. Distinct from Upload::AUDIOBOOK_EXTENSIONS, which also treats
  # zip/rar archives as audiobook uploads — those are not present in a watched
  # completed-download folder as playable media.
  AUDIO_EXTENSIONS = %w[m4a m4b mp3 aax aac flac ogg opus wav].freeze
  # Single-file readable formats (ebooks + comics), reused from the download
  # importer so both front doors recognise the same file types.
  READABLE_EXTENSIONS = PostProcessingJob::EBOOK_FILE_EXTENSIONS
  MAX_ONLINE_CANDIDATES = 5

  class AcquisitionConflictError < StandardError; end

  # Outcome of a successful import into the organised library.
  ImportResult = Data.define(:book, :destination_path, :mode, :publication)

  # Read-only identification result. +candidate_books+ is a ranked array of
  # plain hashes safe to persist as JSON on a DetectedImport.
  Identification = Data.define(
    :book_type,
    :parsed_title,
    :parsed_author,
    :suggested_book,
    :candidate_books,
    :match_confidence,
    :source_path
  )

  class << self
    # Inspect a source file and return a ranked suggestion. No writes.
    #
    # source_path   - a regular file to read embedded metadata from. For an
    #                 audiobook folder the caller passes a representative audio
    #                 file inside it.
    # book_type     - optional override; inferred from the path when omitted.
    # filename_hint - name used for the filename-parse fallback (defaults to the
    #                 source basename; the caller passes the folder name for an
    #                 audiobook so the parse reflects the release, not one track).
    def identify(source_path:, book_type: nil, filename_hint: nil, online: true)
      resolved_type = (book_type || infer_book_type(source_path)).to_s
      extracted = MetadataExtractorService.extract(source_path)
      parsed = FilenameParserService.parse(filename_hint.presence || File.basename(source_path.to_s))

      title = extracted.title.presence || parsed.title
      author = extracted.author.presence || parsed.author

      match = BookMatcherService.match(title: title, author: author, book_type: resolved_type)
      suggested_book = match.book if match.exact? || match.fuzzy?

      candidates = []
      candidates << library_candidate(match.book, match.score) if suggested_book
      candidates.concat(online_candidates(title, author, resolved_type)) if online

      confidence = if suggested_book
        match.score
      elsif extracted.present?
        90
      else
        parsed.confidence
      end

      Identification.new(
        book_type: resolved_type,
        parsed_title: title,
        parsed_author: author,
        suggested_book: suggested_book,
        candidate_books: candidates,
        match_confidence: confidence,
        source_path: source_path.to_s
      )
    end

    # Infer a book type from a path without reading it. A directory is treated
    # as an audiobook release; a file is classified by extension.
    def infer_book_type(source_path)
      return "audiobook" if File.directory?(source_path)

      case File.extname(source_path.to_s).delete_prefix(".").downcase
      when *Upload::COMICBOOK_EXTENSIONS then "comicbook"
      when *AUDIO_EXTENSIONS then "audiobook"
      else "ebook"
      end
    end

    # Import an already-decided book's source file into the organised library,
    # marking the book acquired and triggering a library scan.
    #
    # source_path - file or directory to publish.
    # book        - the target Book (must not already be acquired/reserved).
    # owner       - the record that owns the acquisition reservation for the
    #               duration of the import (e.g. a DetectedImport). Required so
    #               the reservation bridges the gap between the pre-import check
    #               and the file_path claim, exactly like the upload path.
    # mode        - copy / move / hardlink; defaults to the configured
    #               completed_download_import_mode.
    # source_identity - optional [device, inode] recorded when the source was
    #               detected. The importer refuses to publish a source whose
    #               inode no longer matches, so a path swapped between approval
    #               and import cannot substitute different bytes.
    #
    # The publication record is persisted on +owner+ before the database claim,
    # so a crash or a lost claim race can still be reversed precisely: bytes are
    # already on disk at that point and only an exact record of them makes the
    # rollback safe.
    def import!(source_path:, book:, owner:, mode: nil, provenance: nil, source_identity: nil)
      mode = (mode || SettingsService.get(:completed_download_import_mode, default: "copy")).to_s
      base_path = output_base_path(book)

      reserve_book!(book, owner)
      importer = LibraryFileImporter.new(mode: mode)
      claimed = false
      begin
        result = importer.import(
          source: source_path,
          book: book,
          base_path: base_path,
          expected_source_identity: source_identity
        )
        record_publication!(owner, result.publication)

        claim_file_path!(book, result.imported_path, owner)
        # The import owns these bytes from here on; only an explicit undo
        # reverses them.
        claimed = true

        trigger_library_scan(book)
        Rails.logger.info(
          "[LibraryAcquisitionService] Imported #{provenance || 'source'} for book ##{book.id} (mode=#{mode})"
        )
        ImportResult.new(
          book: book,
          destination_path: result.imported_path,
          mode: mode,
          publication: result.publication
        )
      rescue
        # Anything short of a completed claim is reversed, including a tree
        # import that failed partway through: the importer's record covers every
        # file it managed to publish before raising. A reversal that could not
        # finish is logged rather than raised — the original failure is the one
        # worth reporting — but the record is left behind so undo can retry it.
        unless claimed || reverse_publication!(importer.publication_record, owner)
          Rails.logger.error(
            "[LibraryAcquisitionService] Could not fully reverse the failed import for book ##{book.id}; " \
              "some published files remain in the library"
          )
        end
        release_reservation!(book, owner)
        raise
      end
    end

    # Reverse a completed import so the detection returns to the review queue and
    # can be re-imported against a different match (e.g. the admin approved "new
    # book" by mistake when a real match existed).
    #
    # Copy / hardlink imports leave the watched-folder source in place, so undo
    # simply discards the library artifact. A move import consumed the source, so
    # undo returns the artifact to where the scanner found it. Either way the book
    # is un-acquired, and a throwaway book created solely for this import (no
    # metadata, no requests/uploads/owned items) is destroyed rather than left
    # behind un-acquired.
    def undo_import!(detected_import)
      book = detected_import.imported_book
      publication = detected_import.publication_record

      if publication.present?
        # Only a complete reversal earns the state reset below. A file that is
        # no longer the one this import published (renamed, re-tagged, replaced)
        # is left alone, and un-acquiring the book anyway would strand it in the
        # library and let a re-import duplicate it.
        unless reverse_publication!(publication, detected_import)
          raise AcquisitionConflictError,
            "Refusing to undo: the file this import published could not be returned or removed — it has been " \
            "renamed, replaced, or moved since. Resolve it under #{publication['base_path']} and try again."
        end
        refresh_source_identity!(detected_import) if publication["mode"].to_s == "move"
      elsif book&.file_path.present?
        # Without an exact record of what was published there is no safe way to
        # tell this import's files apart from anything else living under the
        # same templated directory, and guessing is how unrelated files get
        # deleted. Leave the artifact and the detection alone for the admin.
        raise AcquisitionConflictError,
          "Refusing to undo: this import predates publication tracking, so #{book.file_path} " \
          "must be removed manually before it can be re-imported"
      end

      ActiveRecord::Base.transaction do
        detected_import.update!(
          status: "detected",
          imported_book: nil,
          suggested_book: nil,
          error_message: nil,
          publication_record: nil
        )
        release_book_after_undo!(book) if book
      end
    end

    def audio_file?(path)
      AUDIO_EXTENSIONS.include?(File.extname(path.to_s).delete_prefix(".").downcase)
    end

    def readable_file?(path)
      READABLE_EXTENSIONS.include?(File.extname(path.to_s).delete_prefix(".").downcase)
    end

    # Compute just the online alternate list for an already-parsed title/author.
    # Used by deferred enrichment so the (networked) provider lookups run off the
    # scan hot path, one queued job per detection, rather than thousands of
    # sequential searches inside a single scan.
    def online_candidates_for(title:, author:, book_type:)
      online_candidates(title, author, book_type.to_s)
    end

    # Run a free-text metadata search for the manual "search for the correct
    # book" step on the review page. Unlike +online_candidates+, results are
    # scored against the admin's query (not the auto-parsed title) and no
    # low-score filter is applied — the admin asked for exactly these, so every
    # provider hit is offered as a selectable candidate in the usual hash shape.
    def search_candidates(query:, book_type:, limit: MAX_ONLINE_CANDIDATES)
      query = query.to_s.strip
      return [] if query.blank?

      content_kind = book_type.to_s == "comicbook" ? "graphic" : nil
      results = MetadataService.search(query, limit: limit, content_kind: content_kind)
      normalized_query = query.downcase
      results.map do |result|
        haystack = [ result.title, result.author ].compact.join(" ").downcase
        {
          "kind" => "online",
          "work_id" => result.work_id,
          "title" => result.title,
          "author" => result.author,
          "year" => result.year,
          "cover_url" => result.cover_url,
          "source" => result.source,
          "score" => string_similarity(haystack, normalized_query)
        }
      end.sort_by { |candidate| -candidate["score"] }
    rescue HardcoverClient::Error, GoogleBooksClient::Error, OpenLibraryClient::Error, MetadataService::Error => e
      Rails.logger.warn "[LibraryAcquisitionService] Manual search failed (#{e.class})"
      []
    end

    private

    # Reserve the book under a row lock so a concurrent acquisition (upload or
    # download) cannot claim the same title while the file import runs outside
    # the transaction. Raises if the title is already acquired or reserved.
    def reserve_book!(book, owner)
      ActiveRecord::Base.transaction do
        book.lock!
        book.reload
        if book.acquisition_blocked?
          raise AcquisitionConflictError,
            "This title already has an acquired or in-progress library file; the existing file was preserved"
        end

        book.update!(
          acquisition_reservation_token: SecureRandom.hex(32),
          acquisition_reservation_owner_type: owner.class.name,
          acquisition_reservation_owner_id: owner.id
        )
      end
    end

    # Attach the imported path and clear the reservation in one compare-and-swap
    # so only the worker still holding this owner's reservation can finalize.
    def claim_file_path!(book, destination, owner)
      claimed = Book.where(id: book.id)
        .where("file_path IS NULL OR TRIM(file_path) = ''")
        .where(
          acquisition_reservation_owner_type: owner.class.name,
          acquisition_reservation_owner_id: owner.id
        )
        .update_all(
          file_path: destination,
          acquisition_reservation_token: nil,
          acquisition_reservation_owner_type: nil,
          acquisition_reservation_owner_id: nil,
          updated_at: Time.current
        )
      raise AcquisitionConflictError, "This title was acquired by another process during import" unless claimed == 1

      book.reload
    end

    def release_reservation!(book, owner)
      Book.where(id: book.id)
        .where(
          acquisition_reservation_owner_type: owner.class.name,
          acquisition_reservation_owner_id: owner.id
        )
        .where("file_path IS NULL OR TRIM(file_path) = ''")
        .update_all(
          acquisition_reservation_token: nil,
          acquisition_reservation_owner_type: nil,
          acquisition_reservation_owner_id: nil,
          updated_at: Time.current
        )
    rescue => e
      Rails.logger.error "[LibraryAcquisitionService] Failed to release reservation for book ##{book.id} (#{e.class})"
    end

    # Persist what an import published so a later rollback or undo can reverse
    # exactly those entries. Written with update_columns so an in-flight import
    # neither runs validations nor broadcasts a status change.
    def record_publication!(owner, publication)
      return unless owner.respond_to?(:publication_record=) && owner.persisted?

      owner.update_columns(publication_record: publication, updated_at: Time.current)
    rescue => e
      Rails.logger.error(
        "[LibraryAcquisitionService] Failed to record publication for #{owner.class.name} ##{owner.id} (#{e.class})"
      )
    end

    # Reverse exactly the entries this import published: discard the files it
    # created (or, for a move, return them to where the scanner found them) and
    # then drop only the directories it brought into existence, and only while
    # they are still empty. A templated "Author/Book" directory is routinely
    # shared with files this import does not own, so it is never deleted
    # recursively.
    #
    # Containment is structural rather than a pathname comparison: every removal
    # walks from the output root through pinned O_NOFOLLOW descriptors and is
    # gated on the (device, inode) recorded at publication, so neither an
    # ancestor swapped for a symlink nor a root that canonicalizes differently
    # (/var vs /private/var) can redirect or block it.
    #
    # Returns true only when every recorded file was reversed. A caller that
    # resets state on the strength of the reversal must not proceed on false:
    # the library still holds an artifact this import put there. The record is
    # kept in that case so undo can be retried once the admin has resolved it;
    # every step is idempotent, so a retry re-reverses only what is left.
    def reverse_publication!(publication, owner)
      publication = publication.presence || {}
      files = Array(publication["files"])
      root = publication["base_path"].presence
      return files.empty? if root.blank?

      move = publication["mode"].to_s == "move"
      complete = files.reverse_each.map { |entry|
        move ? restore_moved_file!(entry, root) : discard_published_file!(entry, root)
      }.all?
      Array(publication["directories"]).reverse_each { |entry| discard_created_directory!(entry, root) }

      clear_publication_record!(owner) if complete
      complete
    end

    def clear_publication_record!(owner)
      return unless owner.respond_to?(:publication_record=) && owner.persisted?

      owner.update_columns(publication_record: nil, updated_at: Time.current)
    rescue => e
      Rails.logger.warn("[LibraryAcquisitionService] Failed to clear publication record (#{e.class})")
    end

    # Copy or hardlink: the watched-folder source is still present, so the
    # library artifact is a redundant second copy — discard it. Returns true
    # when the entry is reversed, which includes finding it already gone.
    def discard_published_file!(entry, root)
      destination = entry["destination"].presence
      return true if destination.blank?

      case published_file_state(entry, root)
      when :absent then return true
      when :match then nil
      else
        Rails.logger.warn(
          "[LibraryAcquisitionService] Left #{destination} in place during undo: " \
            "it is no longer the file this import published"
        )
        return false
      end

      FileCopyService.remove_regular_file_safely(destination, root: root)
      true
    rescue FileCopyService::UnsafePathError, FileCopyService::AtomicPublicationUnsupportedError, SystemCallError => e
      Rails.logger.warn(
        "[LibraryAcquisitionService] Left #{entry['destination']} in place during undo (#{e.class})"
      )
      false
    end

    # Move: the source is gone, so return this file to the path the scanner
    # recorded for it. Restoring per file rebuilds a moved directory tree
    # exactly as it was found. Returns true when the entry is reversed.
    def restore_moved_file!(entry, root)
      destination = entry["destination"].presence
      source = entry["source"].presence
      return true if destination.blank? || source.blank?

      # A directory move publishes every file before unlinking the source tree,
      # so a reversal partway through finds the source still in place. The
      # library copy is then redundant rather than the only surviving one. The
      # same branch makes a retried undo a no-op for entries already returned.
      return discard_published_file!(entry, root) if File.exist?(source)

      unless published_file_state(entry, root) == :match
        Rails.logger.warn(
          "[LibraryAcquisitionService] Could not return #{destination} to #{source}: " \
            "it is no longer the file this import published"
        )
        return false
      end

      FileUtils.mkdir_p(File.dirname(source))
      FileCopyService.mv_noreplace(
        destination, source,
        root: File.dirname(source), allow_compatibility_fallback: true
      )
      true
    rescue FileCopyService::UnsafePathError, FileCopyService::AtomicPublicationUnsupportedError, SystemCallError => e
      Rails.logger.warn(
        "[LibraryAcquisitionService] Could not return #{entry['destination']} to #{entry['source']} (#{e.class})"
      )
      false
    end

    # Drop a directory this import created, but only while it is still exactly
    # as empty as it was left. remove_directory_child_if_identity quarantines it
    # and restores it untouched when anything has since been written into it.
    def discard_created_directory!(entry, root)
      path = entry["path"].presence
      device = entry["device"]
      inode = entry["inode"]
      return if path.blank? || device.blank? || inode.blank?

      FileCopyService.remove_directory_child_if_identity(
        File.dirname(path),
        File.basename(path),
        root: root,
        device: device,
        inode: inode,
        expected_entries: {}
      )
    rescue FileCopyService::UnsafePathError, SystemCallError => e
      Rails.logger.warn("[LibraryAcquisitionService] Left directory #{entry['path']} in place during undo (#{e.class})")
    end

    # Whether the library still holds the exact inode this import published,
    # listed through descriptors pinned to the output root rather than resolved
    # from the pathname.
    #
    #   :match     - the published file is still there, byte for byte the same
    #   :absent    - already gone, so there is nothing left to reverse
    #   :mismatch  - something else now occupies the path; never touch it
    def published_file_state(entry, root)
      device = entry["device"]
      inode = entry["inode"]
      basename = File.basename(entry["destination"])
      children = FileCopyService.directory_children(File.dirname(entry["destination"]), root: root)
      child = children.find { |candidate| candidate.name == basename }
      return :absent unless child
      return :mismatch unless child.type == :file
      return :match if device.blank? || inode.blank?

      [ child.device, child.inode ] == [ device, inode ] ? :match : :mismatch
    rescue Errno::ENOENT
      # The templated directory itself is gone, so the file under it is too.
      :absent
    rescue FileCopyService::UnsafePathError, SystemCallError
      :mismatch
    end

    # A move import that has been undone put the source back with a fresh inode
    # (the restore is a durable copy followed by an unlink, not a rename), so
    # the identity recorded at detection no longer describes it. Re-record it,
    # or drop it when it cannot be read — the importer treats a missing identity
    # as "unverifiable" rather than refusing the re-import outright.
    def refresh_source_identity!(detected_import)
      stat = File.lstat(detected_import.source_path)
      detected_import.update_columns(
        source_device: stat.dev, source_inode: stat.ino, updated_at: Time.current
      )
    rescue SystemCallError, ActiveRecord::RecordNotUnique => e
      Rails.logger.warn("[LibraryAcquisitionService] Clearing source identity after undo (#{e.class})")
      detected_import.update_columns(source_device: nil, source_inode: nil, updated_at: Time.current)
    end

    # Un-acquire the book and destroy it when it was a throwaway created solely
    # for this import (no metadata identity and nothing else references it). A
    # matched or metadata-bearing book is kept, merely un-acquired.
    def release_book_after_undo!(book)
      book.reload
      book.update!(
        file_path: nil,
        acquisition_reservation_token: nil,
        acquisition_reservation_owner_type: nil,
        acquisition_reservation_owner_id: nil
      )

      if book.unified_work_id.blank? &&
          book.requests.none? && book.uploads.none? && book.owned_library_items.none?
        book.destroy
      end
    end

    def output_base_path(book)
      if book.comicbook?
        SettingsService.get(:comicbook_output_path, default: "/comics")
      elsif book.ebook?
        SettingsService.get(:ebook_output_path, default: "/ebooks")
      else
        SettingsService.get(:audiobook_output_path, default: "/audiobooks")
      end
    end

    def trigger_library_scan(book)
      return unless LibraryPlatformClient.configured?

      library_id = SettingsService.library_id_for_book(book)
      return if library_id.blank?

      LibraryPlatformClient.scan_library(library_id)
      Rails.logger.info "[LibraryAcquisitionService] Triggered library scan for book ##{book.id}"
    rescue LibraryPlatformClient::Error => e
      Rails.logger.warn "[LibraryAcquisitionService] Failed to trigger library scan (#{e.class})"
    end

    def library_candidate(book, score)
      {
        "kind" => "library",
        "book_id" => book.id,
        "title" => book.title,
        "author" => book.author,
        "score" => score
      }
    end

    # Best-effort online enrichment. Network/parse failures degrade to an empty
    # alternate list — the human review step is the correctness backstop.
    def online_candidates(title, author, book_type)
      return [] if title.blank?

      query = author.present? ? "#{title} #{author}" : title
      content_kind = book_type.to_s == "comicbook" ? "graphic" : nil
      results = MetadataService.search(query, limit: MAX_ONLINE_CANDIDATES, content_kind: content_kind)
      results.filter_map do |result|
        score = online_score(result, title, author)
        next if score < 30

        {
          "kind" => "online",
          "work_id" => result.work_id,
          "title" => result.title,
          "author" => result.author,
          "year" => result.year,
          "cover_url" => result.cover_url,
          "source" => result.source,
          "score" => score
        }
      end.sort_by { |candidate| -candidate["score"] }
    rescue HardcoverClient::Error, GoogleBooksClient::Error, OpenLibraryClient::Error, MetadataService::Error => e
      Rails.logger.warn "[LibraryAcquisitionService] Metadata search failed (#{e.class})"
      []
    end

    def online_score(result, query_title, query_author)
      score = 0
      if result.title.present? && query_title.present?
        score += (string_similarity(result.title.downcase, query_title.downcase) * 0.6).round
      end
      if result.author.present? && query_author.present?
        score += (string_similarity(result.author.downcase, query_author.downcase) * 0.4).round
      elsif result.author.present?
        score += 10
      end
      score
    end

    def string_similarity(str1, str2)
      return 100 if str1 == str2
      return 0 if str1.blank? || str2.blank?

      trigrams1 = to_trigrams(str1)
      trigrams2 = to_trigrams(str2)
      return 0 if trigrams1.empty? || trigrams2.empty?

      intersection = (trigrams1 & trigrams2).size
      union = (trigrams1 | trigrams2).size
      ((intersection.to_f / union) * 100).round
    end

    def to_trigrams(str)
      padded = "  #{str}  "
      (0..padded.length - 3).map { |i| padded[i, 3] }.to_set
    end
  end
end
