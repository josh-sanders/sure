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
