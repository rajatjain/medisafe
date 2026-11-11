import 'package:flutter/material.dart';

import '../app_name.dart';
import '../services/medicine_catalog.dart';
import 'design.dart';

class CatalogLastUpdated extends StatelessWidget {
  const CatalogLastUpdated(this.updatedAt, {super.key});

  final DateTime updatedAt;

  @override
  Widget build(BuildContext context) {
    final local = updatedAt.toLocal();
    final labels = MaterialLocalizations.of(context);
    final date = labels.formatShortDate(local);
    final time = labels.formatTimeOfDay(
      TimeOfDay.fromDateTime(local),
      alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
    );
    return Text('Last updated $date at $time');
  }
}

class CatalogSettings extends StatelessWidget {
  const CatalogSettings(this.catalog, {super.key});

  final MedicineCatalog catalog;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text(appName)),
    body: SafeArea(
      child: ListenableBuilder(
        listenable: catalog,
        builder: (context, _) {
          final info = catalog.sourcePresent ? catalog.info : null;
          final status = switch ((catalog.indexing, info)) {
            (true, null) => 'Preparing medicine suggestions…',
            (true, _) => 'Updating medicine suggestions…',
            (false, final ready?) =>
              '${MaterialLocalizations.of(context).formatDecimal(ready.count)} medicine names available offline.',
            _ => 'No medicine catalog available. You can enter names manually.',
          };
          return AppList(
            children: [
              const PageTitle(
                'Medicine catalog',
                subtitle: 'Offline name suggestions',
              ),
              SectionCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(status),
                    if (info?.updatedAt case final updatedAt?) ...[
                      const SizedBox(height: Space.xs),
                      CatalogLastUpdated(updatedAt),
                    ],
                    if (catalog.indexing) ...[
                      const SizedBox(height: Space.sm),
                      const LinearProgressIndicator(),
                    ],
                    if ((catalog.error ?? catalog.downloadError)
                        case final error?) ...[
                      const SizedBox(height: Space.sm),
                      Text(
                        error,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (info != null)
                SectionCard(
                  child: ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    title: const Text('Catalog source and licence'),
                    children: [
                      const Text(
                        'Common Drug Codes for India by NRCeS and C-DAC, Pune. '
                        '$appName indexes the medicine names for search.',
                      ),
                      const SizedBox(height: Space.sm),
                      const SelectableText('https://www.nrces.in/resources'),
                      const SizedBox(height: Space.md),
                      SelectableText(info.license),
                    ],
                  ),
                ),
            ],
          );
        },
      ),
    ),
  );
}
