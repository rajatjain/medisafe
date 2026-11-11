import 'package:flutter/material.dart';

enum AppPalette {
  plum('Plum', Color(0xFF7C35AB), Color(0xFFFBF8FD)),
  sage('Sage', Color(0xFF087354), Color(0xFFF5FAF7)),
  ocean('Ocean', Color(0xFF0069C4), Color(0xFFF4F9FF)),
  terracotta('Terracotta', Color(0xFFB74025), Color(0xFFFFF8F4)),
  slate('Slate', Color(0xFF435D9D), Color(0xFFF6F8FD));

  const AppPalette(this.label, this.seed, this.paper);

  final String label;
  final Color seed;
  final Color paper;

  static AppPalette fromName(String name) =>
      values.firstWhere((theme) => theme.name == name, orElse: () => plum);
}

class Space {
  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 16.0;
  static const xl = 24.0;
  static const radius = 20.0;
}

ThemeData appTheme(AppPalette palette, Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final colors =
      ColorScheme.fromSeed(
        seedColor: palette.seed,
        brightness: brightness,
        dynamicSchemeVariant: DynamicSchemeVariant.fidelity,
      ).copyWith(
        primary: dark ? null : palette.seed,
        onPrimary: dark ? null : Colors.white,
        surface: dark ? const Color(0xFF19171C) : palette.paper,
      );
  final base = ThemeData(useMaterial3: true, colorScheme: colors);
  return base.copyWith(
    scaffoldBackgroundColor: colors.surface,
    appBarTheme: AppBarTheme(
      backgroundColor: colors.surface,
      scrolledUnderElevation: 0,
      titleTextStyle: base.textTheme.titleMedium?.copyWith(
        color: colors.onSurface,
        fontWeight: FontWeight.w700,
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: colors.surfaceContainerLowest,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(Space.md)),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(Space.md),
        borderSide: BorderSide(color: colors.primary, width: 2),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(64, 48),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Space.lg),
        ),
        textStyle: base.textTheme.labelLarge?.copyWith(
          fontWeight: FontWeight.w700,
        ),
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: colors.surfaceContainerLowest,
      indicatorColor: colors.primaryContainer,
      iconTheme: WidgetStateProperty.resolveWith(
        (states) => IconThemeData(
          color: states.contains(WidgetState.selected)
              ? colors.onPrimaryContainer
              : colors.onSurfaceVariant,
        ),
      ),
      elevation: 0,
    ),
    listTileTheme: ListTileThemeData(
      titleTextStyle: base.textTheme.bodyLarge?.copyWith(
        color: colors.onSurface,
        fontWeight: FontWeight.w600,
        letterSpacing: 0,
      ),
    ),
    cardTheme: CardThemeData(
      color: colors.surfaceContainerLowest,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Space.radius),
        side: BorderSide(color: colors.outlineVariant),
      ),
    ),
    textTheme: base.textTheme.copyWith(
      headlineLarge: base.textTheme.headlineLarge?.copyWith(
        fontSize: 34,
        height: 1.15,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.55,
      ),
      titleMedium: base.textTheme.titleMedium?.copyWith(
        fontWeight: FontWeight.w700,
      ),
    ),
  );
}

class MedisafeBrand extends StatelessWidget {
  const MedisafeBrand({super.key});

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Image.asset(
        'assets/branding/medisafe-logo.png',
        width: 36,
        height: 36,
        excludeFromSemantics: true,
      ),
      const SizedBox(width: Space.sm),
      const Flexible(child: Text('Medisafe', overflow: TextOverflow.ellipsis)),
    ],
  );
}

class PageTitle extends StatelessWidget {
  const PageTitle(this.title, {this.eyebrow, this.subtitle, super.key});

  final String title;
  final String? eyebrow;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (eyebrow != null) ...[
          Text(
            eyebrow!,
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.primary,
              letterSpacing: 1.1,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: Space.xs),
        ],
        Semantics(
          header: true,
          child: Text(title, style: theme.textTheme.headlineLarge),
        ),
        if (subtitle != null) ...[
          const SizedBox(height: Space.sm),
          Text(
            subtitle!,
            style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ],
    );
  }
}

class SectionCard extends StatelessWidget {
  const SectionCard({required this.child, this.highlight = false, super.key});

  final Widget child;
  final bool highlight;

  @override
  Widget build(BuildContext context) => Card(
    color: highlight ? Theme.of(context).colorScheme.primaryContainer : null,
    child: Padding(padding: const EdgeInsets.all(Space.lg), child: child),
  );
}

class LeadingIcon extends StatelessWidget {
  const LeadingIcon(this.icon, {super.key});

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      width: 42,
      height: 42,
      decoration: BoxDecoration(
        color: colors.primaryContainer,
        borderRadius: BorderRadius.circular(13),
      ),
      child: Icon(icon, size: 22, color: colors.onPrimaryContainer),
    );
  }
}

class StatusPill extends StatelessWidget {
  const StatusPill(
    this.label, {
    this.warning = false,
    this.complete = false,
    super.key,
  });

  final String label;
  final bool warning;
  final bool complete;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final (background, foreground) = warning
        ? (colors.errorContainer, colors.onErrorContainer)
        : complete
        ? (colors.tertiaryContainer, colors.onTertiaryContainer)
        : (colors.secondaryContainer, colors.onSecondaryContainer);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(32),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Space.sm,
          vertical: Space.xs,
        ),
        child: Text(
          label,
          style: TextStyle(
            color: foreground,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

class AppActions extends StatelessWidget {
  const AppActions({required this.children, super.key});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: Space.sm,
    runSpacing: Space.sm,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: children,
  );
}

class AppList extends StatelessWidget {
  const AppList({required this.children, super.key});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => ListView.separated(
    padding: const EdgeInsets.fromLTRB(Space.xl, Space.xl, Space.xl, Space.xl),
    itemCount: children.length,
    itemBuilder: (_, index) => children[index],
    separatorBuilder: (_, _) => const SizedBox(height: Space.md),
  );
}

String clockLabel(BuildContext context, int minutes) =>
    MaterialLocalizations.of(context).formatTimeOfDay(
      TimeOfDay(hour: minutes ~/ 60, minute: minutes % 60),
      alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
    );

String dateLabel(BuildContext context, DateTime date) =>
    MaterialLocalizations.of(context).formatMediumDate(date);

String timestamp(BuildContext context, DateTime date) {
  final local = date.toLocal();
  return '${dateLabel(context, local)} · ${clockLabel(context, local.hour * 60 + local.minute)}';
}

Future<bool> confirm(
  BuildContext context,
  String title,
  String body,
  String verb,
) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(verb),
          ),
        ],
      ),
    ) ??
    false;

class TimeField extends StatelessWidget {
  const TimeField({
    required this.label,
    required this.minutes,
    required this.onChanged,
    super.key,
  });

  final String label;
  final int? minutes;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) => FormField<int>(
    initialValue: minutes,
    validator: (_) => minutes == null ? 'Choose a time' : null,
    builder: (state) => InkWell(
      borderRadius: BorderRadius.circular(Space.md),
      onTap: () async {
        final value = minutes;
        final chosen = await showTimePicker(
          context: context,
          initialTime: value == null
              ? TimeOfDay.now()
              : TimeOfDay(hour: value ~/ 60, minute: value % 60),
        );
        if (chosen == null || !context.mounted) return;
        final result = chosen.hour * 60 + chosen.minute;
        state.didChange(result);
        onChanged(result);
      },
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          errorText: state.errorText,
          suffixIcon: const Icon(Icons.schedule),
        ),
        isEmpty: minutes == null,
        child: Text(
          minutes == null ? 'Select time' : clockLabel(context, minutes!),
        ),
      ),
    ),
  );
}
