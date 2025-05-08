//
//  gitwhisper
//  utils.dart
//
//  Created by Ngonidzashe Mangudya on 2025/05/08.
//  Copyright (c) 2025 Codecraft Solutions. All rights reserved.
//

import 'dart:math' show max;
import 'package:ansicolor/ansicolor.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:mason_logger/mason_logger.dart';

void renderMarkdownText(String text, {required Logger logger}) {
  final parsed = md.Document().parseLines(text.split('\n'));

  for (final node in parsed) {
    logger.info(renderNode(node));
  }
}

String renderNode(md.Node node, {int indent = 0}) {
  try {
    // Default pens - guard against null pointers
    final boldPen = AnsiPen()..white(bold: true);
    final italicPen = AnsiPen()..cyan();
    final codePen = AnsiPen()..yellow();
    final linkPen = AnsiPen()..blue();
    final headerPens = [
      AnsiPen()..green(bold: true),
      AnsiPen()..blue(bold: true),
      AnsiPen()..magenta(bold: true),
      AnsiPen()..red(bold: true),
      AnsiPen()..xterm(202), // orange
      AnsiPen()..gray(level: 0.5),
    ];
    final quotePen = AnsiPen()..gray(level: 0.5);
    final hrPen = AnsiPen()..gray(level: 0.5);

    // Handle empty case
    if (node.textContent.isEmpty) return '';

    if (node is md.Element) {
      final tag = node.tag;
      final children = node.children;

      switch (tag) {
        case 'h1':
        case 'h2':
        case 'h3':
        case 'h4':
        case 'h5':
        case 'h6':
          try {
            final level = int.parse(tag.substring(1)) - 1;
            final pen = headerPens[level.clamp(0, headerPens.length - 1)];
            return '\n${pen('${'#' * (level + 1)} ${node.textContent}')}\n';
          } catch (e) {
            // Fallback if parsing fails
            return '\n${headerPens[0]('# ${node.textContent}')}\n';
          }

        case 'p':
          try {
            final content = children?.map(renderNode).join() ?? '';
            return '${'  ' * indent}$content\n';
          } catch (e) {
            return '${'  ' * indent}${node.textContent}\n';
          }

        case 'strong':
          try {
            return boldPen(children?.map(renderNode).join() ?? '');
          } catch (e) {
            return boldPen(node.textContent);
          }

        case 'em':
          try {
            return italicPen(children?.map(renderNode).join() ?? '');
          } catch (e) {
            return italicPen(node.textContent);
          }

        case 'code':
          return codePen('`${node.textContent}`');

        case 'pre':
          try {
            final codeContent = node.textContent.trim();
            if (codeContent.isEmpty) return '\n```\n```\n';

            final lines = codeContent.split('\n');
            final paddedLines = lines.map((line) => '  $line').join('\n');
            return '\n${codePen('```\n$paddedLines\n```')}\n';
          } catch (e) {
            return '\n${codePen('```\n${node.textContent}\n```')}\n';
          }

        case 'blockquote':
          try {
            final content = children?.isEmpty ?? true
                ? ''
                : children
                        ?.map((c) => renderNode(c, indent: indent))
                        .join('\n') ??
                    '';

            // Handle empty content
            if (content.trim().isEmpty) return quotePen('>\n');

            // Format each line with quote indicator
            final quotedLines = content
                .split('\n')
                .map((line) => line.isEmpty ? '>' : '> $line')
                .join('\n');
            return quotePen('$quotedLines\n');
          } catch (e) {
            return quotePen('> ${node.textContent}\n');
          }

        case 'ul':
        case 'ol':
          try {
            if (children?.isEmpty ?? true) return '';

            final isOrdered = tag == 'ol';
            final items = <String>[];

            for (int i = 0; i < (children?.length ?? 0); i++) {
              try {
                final child = children![i];
                final bullet = isOrdered ? '${i + 1}.' : '•';
                final content =
                    renderNode(child, indent: indent + 1).trimRight();
                items.add('${'  ' * indent}$bullet $content');
              } catch (e) {
                // Skip problematic items
                continue;
              }
            }

            return '${items.join('\n')}\n';
          } catch (e) {
            return '${'  ' * indent}• ${node.textContent}\n';
          }

        case 'li':
          try {
            return children
                    ?.map((c) => renderNode(c, indent: indent))
                    .join(' ')
                    .trim() ??
                '';
          } catch (e) {
            return node.textContent;
          }

        case 'a':
          try {
            final text = children?.map(renderNode).join() ?? '[link]';
            final url = node.attributes['href'] ?? '';
            return linkPen('$text${url.isNotEmpty ? ' [$url]' : ''}');
          } catch (e) {
            return linkPen('[link]');
          }

        case 'img':
          try {
            final altText = node.attributes['alt'] ?? '[Image]';
            final url = node.attributes['src'] ?? '';
            return '[Image: $altText${url.isNotEmpty ? ' ($url)' : ''}]';
          } catch (e) {
            return '[Image]';
          }

        case 'hr':
          return hrPen('\n${'-' * 80}\n');

        case 'br':
          return '\n';

        case 'table':
          try {
            return renderTable(node, indent);
          } catch (e) {
            return '\n[Table: Unable to render]\n';
          }

        default:
          try {
            return children?.map(renderNode).join() ?? node.textContent;
          } catch (e) {
            return node.textContent;
          }
      }
    } else if (node is md.Text) {
      return node.text;
    }

    // Fallback for unknown node types
    return node.toString();
  } catch (e) {
    // Ultimate fallback if anything goes wrong
    return '[Error rendering markdown]';
  }
}

// Helper function for table rendering with exception handling
String renderTable(md.Element table, int indent) {
  try {
    if (table.children == null || table.children!.isEmpty) {
      return '';
    }

    final rows = <List<String>>[];
    final columnWidths = <int>[];

    // Process header safely
    md.Element? header;
    final children = table.children;
    if (children != null && children.isNotEmpty) {
      final firstChild = children.first;
      if (firstChild is md.Element && firstChild.tag == 'thead') {
        header = firstChild;
      }
    }

    // Process body safely
    md.Element? body;
    if (children != null && children.length > (header != null ? 1 : 0)) {
      final bodyCandidate = children[header != null ? 1 : 0];
      if (bodyCandidate is md.Element && bodyCandidate.tag == 'tbody') {
        body = bodyCandidate;
      }
    }

    // Extract header cells safely
    if (header != null) {
      final headerChildren = header.children;
      if (headerChildren != null && headerChildren.isNotEmpty) {
        final firstHeaderRow = headerChildren.first;
        if (firstHeaderRow is md.Element) {
          final headerCells = firstHeaderRow.children;
          if (headerCells != null) {
            final headerRow = <String>[];
            for (final cell in headerCells) {
              if (cell is md.Element) {
                headerRow.add(cell.textContent.trim());
              }
            }

            if (headerRow.isNotEmpty) {
              rows.add(headerRow);

              // Initialize column widths
              columnWidths.addAll(headerRow.map((cell) => cell.length));
            }
          }
        }
      }
    }

    // Extract body cells safely
    if (body != null) {
      final bodyRows = body.children;
      if (bodyRows != null) {
        for (final rowNode in bodyRows) {
          if (rowNode is md.Element) {
            final cellNodes = rowNode.children;
            if (cellNodes != null) {
              final row = <String>[];
              for (final cell in cellNodes) {
                if (cell is md.Element) {
                  row.add(cell.textContent.trim());
                }
              }

              if (row.isNotEmpty) {
                rows.add(row);

                // Update column widths
                for (int i = 0; i < row.length; i++) {
                  if (i >= columnWidths.length) {
                    columnWidths.add(0);
                  }
                  columnWidths[i] = max(columnWidths[i], row[i].length);
                }
              }
            }
          }
        }
      }
    }

    // Render table
    if (rows.isEmpty) return '';

    final result = StringBuffer()..writeln();

    // Header row
    if (rows.isNotEmpty) {
      result.write('  ' * indent);
      final headerRow = rows.first;
      for (int i = 0; i < headerRow.length; i++) {
        final cell = headerRow[i];
        final width = i < columnWidths.length ? columnWidths[i] : cell.length;
        result.write('| ${cell.padRight(width)} ');
      }
      result
        ..writeln('|')
        // Separator row
        ..write('  ' * indent);
      for (final width in columnWidths) {
        result.write('| ${'-' * width} ');
      }
      result.writeln('|');

      // Body rows
      for (int r = 1; r < rows.length; r++) {
        result.write('  ' * indent);
        final row = rows[r];
        for (int i = 0; i < row.length; i++) {
          final cell = row[i];
          final width = i < columnWidths.length ? columnWidths[i] : cell.length;
          result.write('| ${cell.padRight(width)} ');
        }
        result.writeln('|');
      }
    }

    return result.toString();
  } catch (e) {
    // Fallback for table rendering errors
    return '\n[Table: Unable to render]\n';
  }
}
