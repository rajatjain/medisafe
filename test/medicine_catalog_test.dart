import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:medisafe/services/medicine_catalog.dart';

Uint8List makeZip(Map<String, String> files) {
  final archive = Archive();
  for (final entry in files.entries) {
    final bytes = utf8.encode(entry.value);
    archive.add(ArchiveFile.bytes('CDCI/${entry.key}', bytes));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

void main() {
  test('imports names with strengths and forms and deduplicates repeats', () {
    final catalog = readCatalogZip(
      makeZip({
        'License.txt': 'Example source licence',
        'BrandMaster.txt':
            '\uFEFFIdentifier\tBrand Name\tGeneric Identifier\r\n'
            '1\tExample 500 mg oral tablet\t3\r\n'
            '2\tEXAMPLE 500 MG ORAL TABLET\t3\r\n'
            '3\tExample 120 mg/5 mL oral suspension\t4\r\n',
        'GenericMaster.txt':
            'Identifier\tGeneric Name\r\n3\tExample generic 500 mg oral tablet\r\n',
      }),
    );

    expect(catalog.names, [
      'Example 500 mg oral tablet',
      'Example 120 mg/5 mL oral suspension',
      'Example generic 500 mg oral tablet',
    ]);
    expect(catalog.license, 'Example source licence');
    expect(catalogSearchKey('Example 120 mg/5 mL'), 'example 120 mg 5 ml');
  });

  test('rejects an unrelated ZIP instead of creating an empty catalog', () {
    final bytes = makeZip({
      'License.txt': 'Example',
      'README.txt': 'Unrelated',
    });
    expect(() => readCatalogZip(bytes), throwsFormatException);
  });
}
