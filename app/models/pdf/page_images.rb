# Spike: each page of a PDF as a PNG, in order, rendered one of two ways:
#
# - :vips (default): ruby-vips, in process. libvips renders PDFs with
#   poppler, the engine behind pdftoppm. Active Storage blocks libvips's
#   untrusted operations at boot (Vips.block_untrusted), the PDF loader among
#   them, so this unblocks only that loader, only while rendering, and blocks
#   it again. The block is process-wide, so for that moment any libvips call
#   in the process can decode a PDF, and poppler parses the upload inside
#   this process.
# - :pdftoppm: Sure's call today (Provider::Openai::PdfProcessor), in a
#   child process, plus a last page for max_pages.
#
# Errors propagate: Vips::Error, or Error when pdftoppm fails.
module Pdf::PageImages
  Error = Class.new(StandardError)
  DPI = 150   # what Provider::Openai::PdfProcessor asks pdftoppm for
  LOADER = "VipsForeignLoadPdf".freeze
  UNBLOCKED = Mutex.new

  def self.pages(content, dpi: DPI, max_pages: nil, renderer: :vips)
    case renderer
    when :vips then vips(content, dpi:, max_pages:)
    when :pdftoppm then pdftoppm(content, dpi:, max_pages:)
    else raise ArgumentError, "unknown renderer #{renderer.inspect}"
    end
  end

  def self.vips(content, dpi:, max_pages:)
    with_pdf_loader do
      count = Vips::Image.pdfload_buffer(content).get("n-pages")
      count = [ count, max_pages ].min if max_pages
      Array.new(count) { |page| Vips::Image.pdfload_buffer(content, page:, dpi:).write_to_buffer(".png") }
    end
  end

  def self.pdftoppm(content, dpi:, max_pages:)
    Dir.mktmpdir do |dir|
      pdf = File.join(dir, "input.pdf")
      File.binwrite(pdf, content)
      last_page = max_pages ? [ "-l", max_pages.to_s ] : []
      ran = system("pdftoppm", "-png", "-r", dpi.to_s, *last_page, pdf, File.join(dir, "page"))
      raise Error, ran.nil? ? "pdftoppm is not installed" : "pdftoppm failed" unless ran

      Dir[File.join(dir, "page-*.png")].sort.map { File.binread(_1) }
    end
  end

  def self.with_pdf_loader
    UNBLOCKED.synchronize do
      Vips.block(LOADER, false)
      yield
    ensure
      Vips.block(LOADER, true)
    end
  end
  private_class_method :vips, :pdftoppm, :with_pdf_loader
end
