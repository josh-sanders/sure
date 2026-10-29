require_relative "../ai/spike_helper"

# Spike: Sure's VectorStore::Openai (ruby-openai) live with the two sample
# statements, on a key without credits: create a store, upload both PDFs,
# wait for OpenAI to index them (Sure doesn't wait), search, then Sure's
# remove_file and delete_store. Everything the run creates is deleted at
# the end, the uploaded files included, which Sure's own calls leave behind.
class VectorStore::OpenaiLiveTest < ActiveSupport::TestCase
  include AiSpikeHelper

  FILES = Rails.root.join("test/fixtures/files/statements")
  QUERIES = {
    "rent" => "monthly apartment rent payment",
    "payroll" => "payroll preauthorized credit",
    "check" => "check 1239 amount"
  }.freeze

  setup do
    @store = VectorStore::Openai.new(access_token: ENV.fetch("SPIKE_OPENAI_API_KEY", "sk-openai"))
    @client = @store.send(:client)
    @log = []
  end

  def note(step, value) = (@log << [ step, value ]).last.last

  # GET until the file leaves in_progress. Replays without sleeping.
  def indexed(store_id, file_id)
    30.times do
      file = @client.vector_store_files.retrieve(vector_store_id: store_id, id: file_id)
      return file unless file["status"] == "in_progress"

      sleep 2 if recording?
    end
  end

  def file_exists?(file_id)
    @client.files.retrieve(id: file_id)
    true
  rescue Faraday::ResourceNotFound
    false
  end

  test "create a store, upload both statements, search, remove (live)" do
    with_spike_cassette("openai/vector_store_statements") do
      created = note(:create_store, @store.create_store(name: "Sure spike statements"))
      assert created.success?, created.error&.message
      store_id = created.data[:id]

      begin
        uploads = %w[bac_ocr impact_scanned].to_h do |name|
          [ name, note(:"upload_#{name}", @store.upload_file(store_id:, file_content: FILES.join("#{name}.pdf").binread, filename: "#{name}.pdf")) ]
        end
        assert uploads.values.all?(&:success?), uploads.values.filter_map { _1.error&.message }.join("; ")
        @file_ids = uploads.transform_values { _1.data[:file_id] }

        @status = @file_ids.transform_values do |file_id|
          file = indexed(store_id, file_id)
          note(:indexed, file.slice("status", "usage_bytes", "last_error"))
        end

        @results = QUERIES.transform_values do |query|
          response = @store.search(store_id:, query:, max_results: 5)
          note(:search, response.success? ? response.data.map { _1.slice(:filename, :score).merge(text: _1[:content].truncate(80)) } : response.error.message)
        end

        @removed = @file_ids.transform_values { @store.remove_file(store_id:, file_id: _1).success? }
      ensure
        @deleted_store = @store.delete_store(store_id:).success?
        # What Sure's calls leave behind: the uploaded files themselves.
        @files_left = @file_ids.to_h.transform_values { file_exists?(_1) }
        @file_ids.to_h.each_value { @client.files.delete(id: _1) rescue nil }
        @files_after_cleanup = @file_ids.to_h.transform_values { file_exists?(_1) }
      end
    end

    puts "\n" + @log.map { |step, value| "  #{step}: #{value.respond_to?(:success?) ? (value.success? ? value.data : value.error.message) : value}" }.join("\n") if recording? || ENV["SPIKE_PRINT"]
    puts "  status=#{@status.inspect}\n  results=#{@results.inspect}\n  removed=#{@removed.inspect} store_deleted=#{@deleted_store} files_left=#{@files_left.inspect} after_cleanup=#{@files_after_cleanup.inspect}" if recording? || ENV["SPIKE_PRINT"]
    # The scan indexes as completed with nothing in it, and no error; Sure
    # marks every upload ready without asking.
    assert_equal({ "status" => "completed", "usage_bytes" => 3592, "last_error" => nil }, @status["bac_ocr"])
    assert_equal({ "status" => "completed", "usage_bytes" => 0, "last_error" => nil }, @status["impact_scanned"])

    # The statement with text is the one chunk every search finds, relevant
    # or not: there's no score threshold, in OpenAI's search or in Sure's tool.
    assert_equal [ 1, 1, 1 ], @results.values.map(&:size)
    rent, payroll, check = @results.values_at("rent", "payroll", "check").map(&:sole)
    assert_operator rent[:score], :>, 0.8
    assert_operator payroll[:score], :<, 0.2, "the payroll lines are in the scan, which has no text"
    assert_operator check[:score], :<, 0.2
    # Search results name Sure's Tempfile, not the user's file.
    assert_match(/\Abac_ocr\d{8}-\d+-\w+\.pdf\z/, rent[:filename])

    # Sure's remove_file and delete_store succeed and leave the uploads on OpenAI.
    assert_equal({ "bac_ocr" => true, "impact_scanned" => true }, @removed)
    assert @deleted_store
    assert_equal({ "bac_ocr" => true, "impact_scanned" => true }, @files_left)
    assert_equal({ "bac_ocr" => false, "impact_scanned" => false }, @files_after_cleanup, "the spike deletes them itself")
  end
end
