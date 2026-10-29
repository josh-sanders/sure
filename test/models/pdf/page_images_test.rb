require "test_helper"

class Pdf::PageImagesTest < ActiveSupport::TestCase
  def statement(name) = file_fixture("statements/#{name}.pdf").binread

  def size(png) = Vips::Image.new_from_buffer(png, "").then { [ _1.width, _1.height ] }

  test "renders every page as a PNG at 150 dpi, a scan included" do
    pages = Pdf::PageImages.pages(statement("impact_scanned"))

    assert_equal 2, pages.size
    assert pages.all? { _1.start_with?("\x89PNG".b) }
    assert_equal [ [ 1275, 1650 ] ] * 2, pages.map { size(_1) }, "US Letter at 150 dpi, as pdftoppm renders it"
  end

  test "max_pages and dpi" do
    pages = Pdf::PageImages.pages(statement("impact_scanned"), dpi: 72, max_pages: 1)

    assert_equal [ [ 612, 792 ] ], pages.map { size(_1) }
  end

  test "pdftoppm renders the same pages, give or take a pixel" do
    skip "pdftoppm isn't installed" unless system("pdftoppm", "-v", out: File::NULL, err: File::NULL)

    { "impact_scanned" => [ [ 1275, 1650 ] ] * 2, "bac_ocr" => [ [ 933, 1219 ] ] }.each do |name, sizes|
      assert_equal sizes, Pdf::PageImages.pages(statement(name), renderer: :pdftoppm).map { size(_1) }
    end
    assert_equal [ [ 932, 1218 ] ], Pdf::PageImages.pages(statement("bac_ocr")).map { size(_1) }, "vips rounds the odd page size down"
    assert_raises(Pdf::PageImages::Error) { Pdf::PageImages.pages("not a pdf", renderer: :pdftoppm) }
  end

  test "a file that isn't a PDF is refused before either renderer runs" do
    assert_raises(Pdf::PageImages::Error) { Pdf::PageImages.pages("not a pdf") }
    assert_raises(Vips::Error) { Pdf::PageImages.pages("not a pdf", max_pixels: nil) }
  end

  # A minimal valid PDF of blank pages, each `size` points.
  def blank_pdf(pages:, size: [ 612, 792 ])
    objects = [ "<< /Type /Catalog /Pages 2 0 R >>",
                "<< /Type /Pages /Kids [#{(0...pages).map { "#{3 + _1} 0 R" }.join(" ")}] /Count #{pages} >>" ] +
              Array.new(pages) { "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 #{size.join(" ")}] >>" }
    pdf = +"%PDF-1.4\n"
    offsets = objects.each_with_index.map { |object, i| pdf.bytesize.tap { pdf << "#{i + 1} 0 obj\n#{object}\nendobj\n" } }
    xref = pdf.bytesize
    pdf << "xref\n0 #{objects.size + 1}\n0000000000 65535 f \n" << offsets.map { format("%010d 00000 n \n", _1) }.join
    pdf << "trailer\n<< /Size #{objects.size + 1} /Root 1 0 R >>\nstartxref\n#{xref}\n%%EOF\n"
  end

  def pdftoppm? = system("pdftoppm", "-v", out: File::NULL, err: File::NULL)

  def timed
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    [ yield, Process.clock_gettime(Process::CLOCK_MONOTONIC) - started ]
  end

  # A stand-in for pdftoppm: a shell script, given the same arguments.
  def fake_pdftoppm(dir, body)
    File.join(dir, "fake-pdftoppm").tap { File.write(_1, "#!/bin/sh\n#{body}\n"); File.chmod(0o755, _1) }
  end

  test "a 300-page upload renders only max_pages pages, with either renderer" do
    skip "pdftoppm isn't installed" unless pdftoppm?

    pdf = blank_pdf(pages: 300)
    %i[pdftoppm vips].each do |renderer|
      pages, seconds = timed { Pdf::PageImages.pages(pdf, renderer:, max_pages: 5) }
      assert_equal 5, pages.size, renderer
      assert_operator seconds, :<, 10, "#{renderer}: the other 295 pages aren't rendered"
    end
  end

  test "a page-size bomb is refused before rendering, with either renderer" do
    bomb = blank_pdf(pages: 1, size: [ 14_400, 14_400 ])   # 200 inches, PDF's largest page: 900 million pixels at 150 dpi

    %i[pdftoppm vips].each do |renderer|
      error = assert_raises(Pdf::PageImages::Error) { Pdf::PageImages.pages(bomb, renderer:) }
      assert_match "page 1 would be 900 million pixels at 150 dpi", error.message
    end
  end

  # Without the size check: a 100-inch page renders unlimited (225 million
  # pixels in about 3 s); under the memory limit poppler can't allocate it,
  # and at 200 inches it refuses by itself. Either way pdftoppm prints "Out
  # of memory" or "Bogus memory allocation size", writes a 1x1 PNG and
  # exits 0, so the page size is checked after rendering too.
  test "without the size check, a page pdftoppm couldn't allocate is caught, not sent as 1x1" do
    skip "pdftoppm isn't installed" unless pdftoppm?

    { 7_200 => 512 * 1024 * 1024, 14_400 => Pdf::PageImages::PDFTOPPM[:memory] }.each do |side, memory|
      bomb = blank_pdf(pages: 1, size: [ side, side ])
      error, seconds = timed { assert_raises(Pdf::PageImages::Error) { Pdf::PageImages.pages(bomb, renderer: :pdftoppm, max_pixels: nil, memory:) } }
      assert_equal "pdftoppm rendered page 1 as 1x1", error.message
      assert_operator seconds, :<, 5
    end
  end

  test "pdftoppm gets an empty environment: no keys or database URL" do
    Dir.mktmpdir do |dir|
      binary = fake_pdftoppm(dir, 'for last; do :; done; env > "$last-1.png"')   # writes its environment where a page would go
      ENV["SPIKE_SECRET_PROBE"] = "s3cret"
      environment = Pdf::PageImages.pages(statement("bac_ocr"), renderer: :pdftoppm, binary:).sole

      assert_no_match(/s3cret|DATABASE_URL|API_KEY|SECRET_KEY_BASE/, environment)
      assert_operator environment.lines.size, :<=, 3, "only what sh sets itself: #{environment.lines.map { _1.split("=").first }.inspect}"
    ensure
      ENV.delete("SPIKE_SECRET_PROBE")
    end
  end

  test "a pdftoppm that hangs is killed, with its whole process group, after the timeout" do
    Dir.mktmpdir do |dir|
      pids = File.join(dir, "pids")
      binary = fake_pdftoppm(dir, "sleep 60 & echo $! > #{pids}; echo $$ >> #{pids}; wait")
      error, seconds = timed { assert_raises(Pdf::PageImages::Error) { Pdf::PageImages.pages(statement("bac_ocr"), renderer: :pdftoppm, binary:, timeout: 1) } }

      assert_equal "pdftoppm took longer than 1s", error.message
      assert_operator seconds, :<, 3
      File.read(pids).split.map(&:to_i).each do |pid|
        assert_raises(Errno::ESRCH, "process #{pid} survived") { Process.kill(0, pid) }
      end
    end
  end

  test "Active Storage blocks the PDF loader; rendering unblocks it only while it runs" do
    pdf = statement("bac_ocr")
    assert_raises(Vips::Error, "blocked at boot") { Vips::Image.pdfload_buffer(pdf) }

    Pdf::PageImages.pages(pdf)
    error = assert_raises(Vips::Error) { Vips::Image.pdfload_buffer(pdf) }
    assert_match "blocked", error.message, "and blocked again afterwards"
  end
end
