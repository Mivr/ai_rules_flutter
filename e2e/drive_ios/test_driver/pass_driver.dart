import 'dart:io';

/// Host driver that passes: exits 0 once the app's VM service URI reached it.
void main() {
  final uri = Platform.environment['VM_SERVICE_URL'];
  if (uri == null || uri.isEmpty) {
    stderr.writeln('DRIVE_PASS_NO_VM_SERVICE: VM_SERVICE_URL is not set');
    exit(2);
  }
  stdout.writeln('DRIVE_PASS_OK: $uri');
}
