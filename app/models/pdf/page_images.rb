# Spike: each page of a PDF as a PNG, in order, rendered one of two ways:
#
# - :pdftoppm: in a child process, hardened beyond Sure's call today
#   (Provider::Openai::PdfProcessor): an empty environment, so the worker's
#   API keys and database URL never reach poppler; its own process group,
#   killed after `timeout` seconds; CPU and address-space limits; and a page
#   range, so a 200-page upload renders max_pages pages, not 200. Its exit
#   status isn't enough: a page it couldn't allocate comes back as a 1x1
#   PNG with exit 0, so each page's size is checked too.
# - :vips: ruby-vips, in process. libvips renders PDFs with poppler, the
#   engine behind pdftoppm. Active Storage blocks libvips's untrusted
#   operations at boot (Vips.block_untrusted), the PDF loader among them, so
#   this unblocks only that loader, only while rendering, and blocks it
#   again. The block is process-wide, so for that moment any libvips call in
#   the process can decode a PDF, and poppler parses the upload inside this
#   process, beyond any process limit.
#
# Both refuse, before rendering, a page that would exceed max_pixels at the
# requested dpi: a page-size bomb (PDF allows 200 inches a side) would
# otherwise allocate gigabytes. Errors propagate: Vips::Error, or Error.
module Pdf::PageImages
  Error = Class.new(StandardError)
  DPI = 150   # what Provider::Openai::PdfProcessor asks pdftoppm for
  MAX_PIXELS = 25_000_000   # about 23 inches square at 150 dpi; US Letter is 2.1 million
  # When poppler can't allocate a page (its own size guard, or the memory
  # limit), pdftoppm prints "Out of memory", writes a 1x1 PNG and exits 0.
  MIN_SIDE = 16
  PDFTOPPM = { binary: "pdftoppm", timeout: 30, cpu_seconds: 60, memory: 1024 * 1024 * 1024 }.freeze
  LOADER = "VipsForeignLoadPdf".freeze
  UNBLOCKED = Mutex.new

  def self.pages(content, dpi: DPI, max_pages: nil, renderer: :vips, max_pixels: MAX_PIXELS, **pdftoppm)
    check_size!(content, dpi:, max_pages:, max_pixels:) if max_pixels
    case renderer
    when :vips then vips(content, dpi:, max_pages:)
    when :pdftoppm then pdftoppm(content, dpi:, max_pages:, **PDFTOPPM, **pdftoppm)
    else raise ArgumentError, "unknown renderer #{renderer.inspect}"
    end
  end

  # From the pages' MediaBox, read by pdf-reader, which already parses
  # every upload in process for its text layer.
  def self.check_size!(content, dpi:, max_pages:, max_pixels:)
    pages = PDF::Reader.new(StringIO.new(content)).pages
    pages = pages.first(max_pages) if max_pages
    pages.each_with_index do |page, i|
      left, bottom, right, top = page.attributes[:MediaBox] || [ 0, 0, 612, 792 ]
      pixels = ((right - left).abs * dpi / 72.0) * ((top - bottom).abs * dpi / 72.0)
      raise Error, "page #{i + 1} would be #{(pixels / 1e6).round} million pixels at #{dpi} dpi" if pixels > max_pixels
    end
  rescue PDF::Reader::MalformedPDFError, PDF::Reader::UnsupportedFeatureError => e
    raise Error, "unreadable PDF: #{e.message}"
  end

  def self.vips(content, dpi:, max_pages:)
    with_pdf_loader do
      count = Vips::Image.pdfload_buffer(content).get("n-pages")
      count = [ count, max_pages ].min if max_pages
      Array.new(count) { |page| Vips::Image.pdfload_buffer(content, page:, dpi:).write_to_buffer(".png") }
    end
  end

  def self.pdftoppm(content, dpi:, max_pages:, binary:, timeout:, cpu_seconds:, memory:)
    executable = binary.include?("/") ? binary : ENV.fetch("PATH", "").split(":").map { File.join(_1, binary) }.find { File.executable?(_1) }
    raise Error, "pdftoppm is not installed" unless executable

    Dir.mktmpdir do |dir|
      pdf = File.join(dir, "input.pdf")
      File.binwrite(pdf, content)
      range = [ "-f", "1", *(max_pages ? [ "-l", max_pages.to_s ] : []) ]
      pid = Process.spawn({}, executable, "-png", "-r", dpi.to_s, *range, pdf, File.join(dir, "page"),
                          unsetenv_others: true, pgroup: true, chdir: dir, in: File::NULL, out: File::NULL, err: File::NULL,
                          rlimit_cpu: cpu_seconds, rlimit_as: memory)
      status = wait(pid, timeout)
      raise Error, "pdftoppm took longer than #{timeout}s" unless status
      raise Error, "pdftoppm failed (#{status.signaled? ? "signal #{status.termsig}" : "exit #{status.exitstatus}"})" unless status.success?

      Dir[File.join(dir, "page-*.png")].sort.map { File.binread(_1) }.each_with_index do |png, i|
        width, height = png.byteslice(16, 8).unpack("NN")
        raise Error, "pdftoppm rendered page #{i + 1} as #{width}x#{height}" if width.to_i < MIN_SIDE || height.to_i < MIN_SIDE
      end
    end
  end

  # The child's status, or nil after killing its whole process group.
  def self.wait(pid, timeout)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      _, status = Process.wait2(pid, Process::WNOHANG)
      return status if status
      break if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.02
    end
    Process.kill("KILL", -pid)
    Process.wait(pid)
    nil
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  end

  def self.with_pdf_loader
    UNBLOCKED.synchronize do
      Vips.block(LOADER, false)
      yield
    ensure
      Vips.block(LOADER, true)
    end
  end
  private_class_method :check_size!, :vips, :pdftoppm, :wait, :with_pdf_loader
end
