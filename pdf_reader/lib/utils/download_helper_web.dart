import 'dart:typed_data';
import 'dart:html' as html;

/// Web-specific download implementation
void downloadBytesOnWeb(Uint8List bytes, String filename, String mimeType) {
  try {
    // Debug logging
    html.window.console.log('Starting download: $filename (${bytes.length} bytes, $mimeType)');
    
    // Create blob with explicit MIME type
    final blob = html.Blob([bytes], mimeType);
    final url = html.Url.createObjectUrlFromBlob(blob);
    
    html.window.console.log('Created blob URL: $url');
    
    // Create anchor element with all attributes set
    final anchor = html.AnchorElement()
      ..href = url
      ..download = filename
      ..target = '_blank'
      ..style.display = 'none';
    
    html.window.console.log('Created anchor element');
    
    // Add to document body
    html.document.body?.children.add(anchor);
    
    html.window.console.log('Added anchor to DOM, attempting click...');
    
    // Trigger download
    anchor.click();
    
    html.window.console.log('Click triggered');
    
    // Clean up immediately but keep URL alive a bit longer
    html.document.body?.children.remove(anchor);
    
    // Clean up URL after a longer delay
    Future.delayed(const Duration(seconds: 1), () {
      try {
        html.Url.revokeObjectUrl(url);
        html.window.console.log('Cleaned up blob URL');
      } catch (e) {
        html.window.console.warn('Failed to revoke URL: $e');
      }
    });
    
    html.window.console.log('Download should have been initiated');
    
  } catch (e) {
    html.window.console.error('Download failed: $e');
    // Try alternative approach
    try {
      html.window.console.log('Trying alternative download method...');
      final blob = html.Blob([bytes], mimeType);
      final url = html.Url.createObjectUrlFromBlob(blob);
      html.window.open(url, '_blank');
      html.window.console.log('Opened in new window as fallback');
    } catch (e2) {
      html.window.console.error('Alternative download also failed: $e2');
    }
    rethrow;
  }
}