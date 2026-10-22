/// Supported document and image conversion types for Filo.
enum ConversionType {
  /// Converts a JPEG image to a PNG image.
  jpgToPng,

  /// Converts a PNG image to a JPEG image.
  pngToJpg,

  /// Converts a single image (e.g. JPG, PNG) into a single PDF document.
  singleImageToPdf,

  /// Combines multiple images into a single multi-page PDF document.
  multipleImagesToPdf,

  /// Extracts or renders pages of a PDF document into individual images.
  pdfToImages,

  /// Converts plain text content or a .txt file into a formatted PDF document.
  txtToPdf,

  /// Extracts text content from a PDF document into a plain text (.txt) format.
  pdfToTxt;

  /// User-friendly display label suitable for presentation in UI.
  String get displayName {
    switch (this) {
      case ConversionType.jpgToPng:
        return 'JPG to PNG';
      case ConversionType.pngToJpg:
        return 'PNG to JPG';
      case ConversionType.singleImageToPdf:
        return 'Image to PDF';
      case ConversionType.multipleImagesToPdf:
        return 'Multiple Images to PDF';
      case ConversionType.pdfToImages:
        return 'PDF to Images';
      case ConversionType.txtToPdf:
        return 'TXT to PDF';
      case ConversionType.pdfToTxt:
        return 'PDF to TXT';
    }
  }

  /// Expected primary output file extension (without dot).
  /// For [pdfToImages], the output may produce multiple image files or an archive,
  /// with primary output images formatted as 'png' or 'jpg'.
  String get defaultOutputExtension {
    switch (this) {
      case ConversionType.jpgToPng:
        return 'png';
      case ConversionType.pngToJpg:
        return 'jpg';
      case ConversionType.singleImageToPdf:
      case ConversionType.multipleImagesToPdf:
      case ConversionType.txtToPdf:
        return 'pdf';
      case ConversionType.pdfToImages:
        return 'png';
      case ConversionType.pdfToTxt:
        return 'txt';
    }
  }

  /// Whether this conversion type supports or requires multiple input files.
  bool get requiresMultipleInputs => this == ConversionType.multipleImagesToPdf;
}
