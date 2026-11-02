import 'package:tlslite/tlslite.dart' as tlslite;

import '../tds_base.dart' as tds;

final Map<String, tlslite.X509Validator> _validators = {};

/// Returns a chain validator for [cafile] (a PEM bundle) or, when it is
/// absent, for the system CA bundle. Each bundle is read once per process.
tlslite.X509Validator certificateValidator(String? cafile) {
  final key = cafile ?? '';
  return _validators[key] ??= _buildValidator(cafile);
}

tlslite.X509Validator _buildValidator(String? cafile) {
  List<tlslite.X509>? anchors;
  if (cafile != null && cafile.isNotEmpty) {
    try {
      anchors = tlslite.loadPemCertificatesFromFile(cafile);
    } catch (error) {
      throw tds.OperationalException(
          'Could not read certificates from $cafile: $error');
    }
    if (anchors.isEmpty) {
      throw tds.OperationalException('No PEM certificate found in $cafile');
    }
  } else {
    anchors = tlslite.loadSystemTrustAnchors();
    if (anchors == null || anchors.isEmpty) {
      throw tds.OperationalException(
        'No system CA bundle was found to validate the server certificate. '
        "Provide cafile (a PEM with the server's CA) or set SSL_CERT_FILE; "
        'trustServerCertificate: true accepts any certificate.',
      );
    }
  }
  return tlslite.X509Validator(anchors);
}
