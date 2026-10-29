# Spike: each page of a PDF as a PNG, in order, through ruby-vips (libvips
# renders PDFs with poppler, the engine behind pdftoppm) instead of shelling
# out to pdftoppm. Errors propagate as Vips::Error.
#
# Active Storage blocks libvips's untrusted operations at boot
# (Vips.block_untrusted), the PDF loader among them. This unblocks only that
# loader, only while rendering, and blocks it again. The block is
# process-wide, so for that moment any libvips call in the process can
# decode a PDF. And poppler parses the upload inside this process, where
# pdftoppm parsed it in a child process of its own.
module Pdf::PageImages
  DPI = 150   # what Provider::Openai::PdfProcessor asks pdftoppm for
  LOADER = "VipsForeignLoadPdf".freeze
  UNBLOCKED = Mutex.new

  def self.pages(content, dpi: DPI, max_pages: nil)
    with_pdf_loader do
      count = Vips::Image.pdfload_buffer(content).get("n-pages")
      count = [ count, max_pages ].min if max_pages
      Array.new(count) { |page| Vips::Image.pdfload_buffer(content, page:, dpi:).write_to_buffer(".png") }
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
  private_class_method :with_pdf_loader
end
