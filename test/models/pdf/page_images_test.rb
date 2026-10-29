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

  test "a file that isn't a PDF raises Vips::Error" do
    assert_raises(Vips::Error) { Pdf::PageImages.pages("not a pdf") }
  end

  test "Active Storage blocks the PDF loader; rendering unblocks it only while it runs" do
    pdf = statement("bac_ocr")
    assert_raises(Vips::Error, "blocked at boot") { Vips::Image.pdfload_buffer(pdf) }

    Pdf::PageImages.pages(pdf)
    error = assert_raises(Vips::Error) { Vips::Image.pdfload_buffer(pdf) }
    assert_match "blocked", error.message, "and blocked again afterwards"
  end
end
