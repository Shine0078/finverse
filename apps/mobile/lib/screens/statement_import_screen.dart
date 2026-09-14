import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../api/client.dart';
import '../api/platform/file_selector_registration.dart';
import '../models/models.dart';

/// Review-first manual statement ingestion. The server is authoritative for
/// parsing, categorization, duplicate detection, and approval; this screen
/// only presents staged rows and sends explicit user decisions.
class StatementImportScreen extends StatefulWidget {
  const StatementImportScreen({required this.api, super.key});

  final ApiClient api;

  @override
  State<StatementImportScreen> createState() => _StatementImportScreenState();
}

class _StatementImportScreenState extends State<StatementImportScreen> {
  List<Account> _accounts = const [];
  List<StatementImport> _history = const [];
  StatementImportDetail? _detail;
  StatementSummary? _summary;
  String? _accountId;
  bool _working = false;
  String? _error;
  final Set<String> _selected = <String>{};

  @override
  void initState() {
    super.initState();
    _loadAccounts();
  }

  Future<void> _loadAccounts() async {
    try {
      final accounts = await widget.api.accounts();
      final history = await widget.api.statementImports();
      if (!mounted) return;
      setState(() {
        _accounts = accounts;
        _history = history;
        _accountId ??= accounts.isEmpty ? null : accounts.first.id;
      });
    } catch (error) {
      if (mounted) setState(() => _error = friendlyErrorMessage(error));
    }
  }

  Future<void> _chooseStatement() async {
    if (_working) return;
    if (_accounts.isEmpty) {
      final account = await _addManualAccount();
      if (!mounted || account == null) return;
      setState(() => _accountId = account.id);
      // A browser file chooser must be opened directly from a user gesture.
      // The account dialog consumes the original gesture, so ask for a
      // second tap instead of silently losing the chooser on the web.
      _showMessage('Account added. Tap Choose statement to select the file.');
      return;
    }
    await _pickAndAnalyze();
  }

  Future<Account?> _addManualAccount() async {
    var name = '';
    var balanceText = '0';
    var currency = 'USD';
    var type = 'checking';
    final submitted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Add account for this statement'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  autofocus: true,
                  onChanged: (value) => name = value,
                  decoration: const InputDecoration(
                    labelText: 'Account name',
                    hintText: 'e.g. Main checking',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: type,
                  decoration: const InputDecoration(
                    labelText: 'Account type',
                    border: OutlineInputBorder(),
                  ),
                  items: const [
                    DropdownMenuItem(
                        value: 'checking', child: Text('Checking')),
                    DropdownMenuItem(value: 'savings', child: Text('Savings')),
                    DropdownMenuItem(value: 'cash', child: Text('Cash')),
                    DropdownMenuItem(
                        value: 'investment', child: Text('Investment')),
                    DropdownMenuItem(
                        value: 'property', child: Text('Property')),
                    DropdownMenuItem(value: 'loan', child: Text('Loan')),
                  ],
                  onChanged: (value) {
                    if (value != null) setDialogState(() => type = value);
                  },
                ),
                const SizedBox(height: 12),
                TextFormField(
                  initialValue: balanceText,
                  onChanged: (value) => balanceText = value,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(
                    labelText: 'Current balance',
                    hintText: '0.00',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  initialValue: currency,
                  onChanged: (value) => currency = value,
                  textCapitalization: TextCapitalization.characters,
                  maxLength: 3,
                  decoration: const InputDecoration(
                    labelText: 'Currency',
                    hintText: 'USD',
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Add account'),
            ),
          ],
        ),
      ),
    );

    name = name.trim();
    currency = currency.trim().toUpperCase();
    final balance = _minorUnits(balanceText);
    if (submitted != true || !mounted) return null;
    if (name.isEmpty ||
        !RegExp(r'^[A-Z]{3}$').hasMatch(currency) ||
        balance == null) {
      _showMessage(
          'Enter an account name, a three-letter currency, and a valid balance.');
      return null;
    }

    setState(() {
      _working = true;
      _error = null;
    });
    try {
      final account = await widget.api.createManualAccount(
        name: name,
        type: type,
        currency: currency,
        balanceCurrent: type == 'loan' ? -balance : balance,
      );
      await _loadAccounts();
      if (mounted) setState(() => _accountId = account.id);
      return account;
    } catch (error) {
      if (mounted) _showError(error);
      return null;
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  int? _minorUnits(String input) {
    final match = RegExp(r'^(\d+)(?:\.(\d{1,2}))?$').firstMatch(input.trim());
    if (match == null) return null;
    final whole = int.tryParse(match.group(1)!);
    final cents = int.tryParse((match.group(2) ?? '').padRight(2, '0')) ?? 0;
    if (whole == null) return null;
    return whole * 100 + cents;
  }

  Future<void> _openExisting(StatementImport item) async {
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      final detail = await _waitForAnalysis(
        await widget.api.statementImport(item.id),
      );
      if (!mounted) return;
      setState(() {
        _detail = detail;
        _accountId = item.accountId;
      });
      await _refreshSummary(item.id);
    } catch (error) {
      if (mounted) setState(() => _error = friendlyErrorMessage(error));
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _pickAndAnalyze() async {
    final accountId = _accountId;
    if (accountId == null) return;
    XFile? file;
    try {
      // Some Flutter web release registrants omit file_selector_web. Register
      // it synchronously here so the chooser remains tied to this click.
      ensureFileSelectorPlatform();
      file = await openFile(
        acceptedTypeGroups: const [
          XTypeGroup(
            label: 'Financial statements',
            extensions: [
              'csv',
              'xlsx',
              'pdf',
              'png',
              'jpg',
              'jpeg',
              'webp',
              'tiff',
              'bmp'
            ],
          ),
        ],
      );
    } catch (error) {
      if (mounted) _showError(error);
      return;
    }
    if (file == null) return;
    setState(() {
      _working = true;
      _error = null;
      _detail = null;
      _summary = null;
      _selected.clear();
    });
    try {
      final bytes = await file.readAsBytes();
      final mime = _mimeFor(file.name);
      final detail =
          await _waitForAnalysis(await widget.api.createStatementImport(
        accountId: accountId,
        filename: file.name,
        mimeType: mime,
        bytes: bytes,
      ));
      if (mounted) setState(() => _detail = detail);
      if (mounted) {
        try {
          final summary =
              await widget.api.statementImportSummary(detail.statement.id);
          if (mounted) setState(() => _summary = summary);
        } catch (_) {
          // The row review remains usable if a summary request is unavailable.
        }
      }
    } catch (error) {
      if (mounted) setState(() => _error = friendlyErrorMessage(error));
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<StatementImportDetail> _waitForAnalysis(
      StatementImportDetail initial) async {
    var current = initial;
    if (current.statement.status != 'queued' &&
        current.statement.status != 'processing') {
      return current;
    }
    for (var attempt = 0; attempt < 60; attempt++) {
      await Future<void>.delayed(const Duration(seconds: 1));
      if (!mounted) return current;
      current = await widget.api.statementImport(current.statement.id);
      if (current.statement.status != 'queued' &&
          current.statement.status != 'processing') {
        return current;
      }
    }
    throw StateError(
        'Analysis is still in progress. Reopen this import shortly to review it.');
  }

  Future<void> _decision(StatementRow row, String decision) async {
    final detail = _detail;
    if (detail == null) return;
    try {
      await widget.api.editStatementRow(
        detail.statement.id,
        row.id,
        {'decision': decision},
      );
      final fresh = await widget.api.statementImport(detail.statement.id);
      if (!mounted) return;
      setState(() {
        _detail = fresh;
      });
      await _refreshSummary(fresh.statement.id);
    } catch (error) {
      if (mounted) _showError(error);
    }
  }

  List<StatementRow> _selectableRows(StatementImportDetail detail) => detail.rows
      .where((row) => row.decision != 'exclude')
      .toList(growable: false);

  void _toggleSelectAll(StatementImportDetail detail, bool selected) {
    final ids = _selectableRows(detail).map((row) => row.id).toSet();
    setState(() {
      if (selected) {
        _selected.addAll(ids);
      } else {
        _selected.removeAll(ids);
      }
    });
  }

  Future<void> _bulkDecision(String decision) async {
    final detail = _detail;
    if (detail == null || _selected.isEmpty) return;
    final ids = _selected.where((id) => detail.rows.any((row) => row.id == id)).toList();
    if (ids.isEmpty) return;
    setState(() => _working = true);
    try {
      await widget.api.decideStatementRows(detail.statement.id, ids, decision);
      final fresh = await widget.api.statementImport(detail.statement.id);
      if (!mounted) return;
      setState(() {
        _detail = fresh;
        _selected.clear();
      });
      await _refreshSummary(fresh.statement.id);
      _showMessage('${ids.length} transactions marked ${decision == 'include' ? 'included' : 'excluded'}.');
    } catch (error) {
      if (mounted) _showError(error);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _editCategory(StatementRow row) async {
    final detail = _detail;
    if (detail == null) return;
    const categories = [
      'unknown',
      'rent',
      'utilities',
      'groceries',
      'restaurants',
      'transportation',
      'shopping',
      'subscriptions',
      'healthcare',
      'entertainment',
      'other_expenses',
      'loan_payment',
      'transfer',
      'fees',
      'savings',
      'investments',
      'income',
      'refunds'
    ];
    final category = await showDialog<String>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('Choose category'),
        children: categories
            .map((value) => SimpleDialogOption(
                  onPressed: () => Navigator.of(dialogContext).pop(value),
                  child: Text(value.replaceAll('_', ' ')),
                ))
            .toList(),
      ),
    );
    if (category == null) return;
    try {
      await widget.api.editStatementRow(detail.statement.id, row.id,
          {'categorySlug': category, 'decision': 'include'});
      final fresh = await widget.api.statementImport(detail.statement.id);
      if (!mounted) return;
      setState(() => _detail = fresh);
      await _refreshSummary(fresh.statement.id);
    } catch (error) {
      if (mounted) _showError(error);
    }
  }

  Future<void> _editRow(StatementRow row) async {
    final detail = _detail;
    if (detail == null) return;
    final date = TextEditingController(text: row.postedAt ?? '');
    final description = TextEditingController(text: row.description);
    final merchant = TextEditingController(text: row.merchant ?? '');
    final amount = TextEditingController(text: row.amount?.toString() ?? '');
    final values = await showDialog<Map<String, String>>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Edit transaction'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
                controller: date,
                decoration:
                    const InputDecoration(labelText: 'Date (YYYY-MM-DD)')),
            TextField(
                controller: description,
                decoration: const InputDecoration(labelText: 'Description')),
            TextField(
                controller: merchant,
                decoration:
                    const InputDecoration(labelText: 'Merchant (optional)')),
            TextField(
                controller: amount,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                    labelText: 'Amount (minor units; negative is debit)')),
          ]),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop({
                    'postedAt': date.text,
                    'description': description.text,
                    'merchant': merchant.text,
                    'amount': amount.text,
                  }),
              child: const Text('Save')),
        ],
      ),
    );
    if (values == null) return;
    final parsedAmount = int.tryParse(values['amount'] ?? '');
    if (parsedAmount == null || parsedAmount == 0) {
      _showMessage('Enter a non-zero amount in minor units.');
      return;
    }
    try {
      await widget.api.editStatementRow(detail.statement.id, row.id, {
        'postedAt': values['postedAt'],
        'description': values['description'],
        'merchant': (values['merchant'] ?? '').trim().isEmpty
            ? null
            : values['merchant'],
        'amount': parsedAmount,
      });
      final fresh = await widget.api.statementImport(detail.statement.id);
      if (!mounted) return;
      setState(() => _detail = fresh);
      await _refreshSummary(fresh.statement.id);
    } catch (error) {
      if (mounted) _showError(error);
    }
  }

  Future<void> _split(StatementRow row) async {
    if (row.amount == null || _detail == null) return;
    final first =
        TextEditingController(text: ((row.amount! / 2).round()).toString());
    final second = TextEditingController(
        text: (row.amount! - (row.amount! / 2).round()).toString());
    final values = await showDialog<List<int>>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Split transaction'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
              controller: first,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                  labelText: 'First amount (minor units)')),
          TextField(
              controller: second,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                  labelText: 'Second amount (minor units)')),
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop([
                    int.tryParse(first.text) ?? 0,
                    int.tryParse(second.text) ?? 0
                  ]),
              child: const Text('Split')),
        ],
      ),
    );
    if (values == null || values.length != 2) return;
    try {
      await widget.api.splitStatementRow(
          _detail!.statement.id,
          row.id,
          values
              .map((amount) =>
                  {'amount': amount, 'categorySlug': row.categorySlug})
              .toList());
      final fresh = await widget.api.statementImport(_detail!.statement.id);
      if (mounted) setState(() => _detail = fresh);
      await _refreshSummary(fresh.statement.id);
    } catch (error) {
      if (mounted) _showError(error);
    }
  }

  Future<void> _merge() async {
    if (_selected.length < 2 || _detail == null) return;
    try {
      await widget.api
          .mergeStatementRows(_detail!.statement.id, _selected.toList());
      final fresh = await widget.api.statementImport(_detail!.statement.id);
      if (mounted) {
        setState(() {
          _detail = fresh;
          _selected.clear();
        });
      }
      await _refreshSummary(fresh.statement.id);
    } catch (error) {
      if (mounted) _showError(error);
    }
  }

  Future<void> _approve() async {
    final detail = _detail;
    if (detail == null) return;
    setState(() => _working = true);
    try {
      final approved =
          await widget.api.approveStatementImport(detail.statement.id);
      if (mounted) {
        setState(() {
          _detail = StatementImportDetail(statement: approved, rows: detail.rows);
          _selected.clear();
        });
        _showMessage('Approved transactions were added to your ledger. Dashboard totals follow the statement dates.');
      }
    } catch (error) {
      if (mounted) _showError(error);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _deleteSource() async {
    final detail = _detail;
    if (detail == null || detail.statement.sourceDeletedAt != null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete original statement?'),
        content: const Text(
            'The encrypted original file will be permanently removed. Approved transactions and their audit history will remain.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Keep file')),
          FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Delete file')),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() => _working = true);
    try {
      await widget.api.deleteStatementSource(detail.statement.id);
      final fresh = await widget.api.statementImport(detail.statement.id);
      if (mounted) {
        setState(() => _detail = fresh);
        _showMessage(
            'Original statement deleted. Approved transactions were kept.');
      }
    } catch (error) {
      if (mounted) _showError(error);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _deleteEmptyImport() async {
    final detail = _detail;
    if (detail == null || detail.rows.isNotEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Remove empty import?'),
        content: const Text(
            'No transactions were saved from this attempt. Remove it so the statement can be analyzed again.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Remove import')),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() => _working = true);
    try {
      await widget.api.deleteStatementImport(detail.statement.id);
      if (!mounted) return;
      setState(() {
        _detail = null;
        _summary = null;
        _selected.clear();
      });
      await _loadAccounts();
      if (mounted) {
        _showMessage('Empty import removed. Choose the statement again.');
      }
    } catch (error) {
      if (mounted) _showError(error);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  void _showError(Object error) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(friendlyErrorMessage(error))));

  void _showMessage(String message) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(message)));

  Future<void> _refreshSummary(String id) async {
    try {
      final summary = await widget.api.statementImportSummary(id);
      if (mounted) setState(() => _summary = summary);
    } catch (_) {
      // The review remains useful if this optional aggregate is unavailable.
    }
  }

  @override
  Widget build(BuildContext context) {
    final detail = _detail;
    return Scaffold(
      appBar: AppBar(title: const Text('Manual statement import')),
      body: RefreshIndicator(
        onRefresh: _loadAccounts,
        child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
            children: [
              const Text(
                  'Upload a statement and FINVERSE will categorize each transaction automatically. You can approve immediately or adjust any row first.'),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                  initialValue: _accountId,
                  decoration: const InputDecoration(labelText: 'Account'),
                  items: _accounts
                      .map((account) => DropdownMenuItem(
                          value: account.id,
                          child: Text('${account.name}  ••${account.mask} · ${account.currency}')))
                      .toList(),
                  onChanged: _working
                      ? null
                      : (value) => setState(() => _accountId = value)),
              if (_accounts.isEmpty) ...[
                const SizedBox(height: 10),
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.account_balance_wallet_outlined),
                    title: const Text('Add an account first'),
                    subtitle: const Text(
                        'Create a checking, savings, investment, property, cash, or loan account for this statement.'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: _working ? null : _addManualAccount,
                  ),
                ),
              ],
              const SizedBox(height: 12),
              FilledButton.icon(
                  onPressed: _working ? null : _chooseStatement,
                  icon: const Icon(Icons.upload_file),
                  label: Text(_working
                      ? 'Processing…'
                      : _accounts.isEmpty
                          ? 'Add account and choose statement'
                          : 'Choose statement')),
              if (_error != null)
                Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(_error!,
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.error))),
              if (detail == null && _history.isNotEmpty) ...[
                const SizedBox(height: 24),
                Text('Previous imports',
                    style: Theme.of(context).textTheme.titleMedium),
                ..._history.map((item) => Card(
                      child: ListTile(
                        leading: Icon(item.status == 'approved'
                            ? Icons.check_circle_outline
                            : item.status == 'failed'
                                ? Icons.error_outline
                                : Icons.rate_review_outlined),
                        title: Text(item.filename,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text(item.status == 'queued' ||
                                item.status == 'processing'
                            ? 'Analysis in progress · ${item.status}'
                            : '${item.rowsNeedsReview} need review · ${item.status}'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: _working ? null : () => _openExisting(item),
                      ),
                    )),
              ],
              if (detail != null) ...[
                const SizedBox(height: 24),
                Text(detail.statement.filename,
                    style: Theme.of(context).textTheme.titleMedium),
                if (detail.statement.documentDetails != null)
                  _documentDetailsView(detail.statement.documentDetails!),
                if (detail.statement.status == 'queued' ||
                    detail.statement.status == 'processing')
                  Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                          'FINVERSE is securely analyzing this statement. This page will show the rows when processing finishes.')),
                if (detail.statement.status == 'failed')
                  Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                          detail.statement.error ??
                              'Statement analysis failed. Upload the file again after checking its format.',
                          style: TextStyle(
                              color: Theme.of(context).colorScheme.error))),
                Text(
                    '${detail.statement.rowsTotal} transactions ready · automatic categorization complete',
                    style: Theme.of(context).textTheme.bodySmall),
                if (detail.statement.status == 'ready' && detail.rows.isEmpty)
                  Card(
                    margin: const EdgeInsets.only(top: 12),
                    child: ListTile(
                      leading: const Icon(Icons.error_outline),
                      title: const Text('No transactions were extracted'),
                      subtitle: const Text(
                          'Remove this empty result, then choose the statement again to reanalyze it.'),
                      trailing: TextButton(
                        onPressed: _working ? null : _deleteEmptyImport,
                        child: const Text('Remove empty import'),
                      ),
                    ),
                  ),
                if (_summary != null) _summaryView(_summary!),
                const SizedBox(height: 8),
                if (detail.statement.status == 'ready' && detail.rows.isNotEmpty) ...[
                  Builder(builder: (context) {
                    final selectable = _selectableRows(detail);
                    final selectedCount = _selected.intersection(selectable.map((row) => row.id).toSet()).length;
                    final allSelected = selectable.isNotEmpty && selectedCount == selectable.length;
                    return Column(
                      children: [
                        CheckboxListTile(
                          contentPadding: EdgeInsets.zero,
                          tristate: true,
                          value: allSelected ? true : selectedCount == 0 ? false : null,
                          onChanged: _working ? null : (value) => _toggleSelectAll(detail, value == true),
                          title: Text(allSelected ? 'Clear selection' : 'Select all transactions'),
                          subtitle: Text('$selectedCount of ${selectable.length} selectable rows selected'),
                          controlAffinity: ListTileControlAffinity.leading,
                        ),
                        if (selectedCount > 0)
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              FilledButton.tonalIcon(
                                onPressed: _working ? null : () => _bulkDecision('include'),
                                icon: const Icon(Icons.check),
                                label: const Text('Include selected'),
                              ),
                              OutlinedButton.icon(
                                onPressed: _working ? null : () => _bulkDecision('exclude'),
                                icon: const Icon(Icons.remove_circle_outline),
                                label: const Text('Exclude selected'),
                              ),
                            ],
                          ),
                      ],
                    );
                  }),
                ],
                if (_selected.length >= 2)
                  Align(
                      alignment: Alignment.centerRight,
                      child: FilledButton.tonalIcon(
                          onPressed: _merge,
                          icon: const Icon(Icons.merge_type),
                          label: const Text('Merge selected'))),
                ...detail.rows.map(_rowTile),
                const SizedBox(height: 12),
                FilledButton.icon(
                    onPressed: _working ||
                            detail.rows.isEmpty ||
                            detail.statement.status != 'ready'
                        ? null
                        : _approve,
                    icon: const Icon(Icons.check),
                    label: Text(detail.statement.status == 'approved'
                        ? 'Approved'
                        : 'Approve transactions now')),
                if (detail.statement.status == 'approved' &&
                    detail.statement.sourceDeletedAt == null) ...[
                  Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                          'The original file can be removed while approved transactions remain in your ledger.',
                          style: Theme.of(context).textTheme.bodySmall)),
                  Align(
                      alignment: Alignment.centerLeft,
                      child: OutlinedButton.icon(
                          onPressed: _working ? null : _deleteSource,
                          icon: const Icon(Icons.delete_outline),
                          label: const Text('Delete original file'))),
                ],
                if (detail.statement.sourceDeletedAt != null)
                  Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                          'Original file deleted; approved transactions remain.',
                          style: Theme.of(context).textTheme.bodySmall)),
              ],
            ]),
      ),
    );
  }

  Widget _rowTile(StatementRow row) {
    final theme = Theme.of(context);
    final incomplete = row.postedAt == null || row.amount == null;
    final category = row.categorySlug == 'unknown'
        ? 'Will be categorized on approval'
        : row.categorySlug.replaceAll('_', ' ');
    final categoryOrigin = switch (row.categorySource) {
      'user_manual' => 'chosen by you',
      'user_rule' => 'matched your rule',
      'model' => 'auto-categorized',
      'lexicon' => 'recognized automatically',
      'transfer_pairing' => 'matched transfer',
      _ => 'auto-categorizes on approval',
    };
    final notes = <String>[
      if (row.flags.contains('possible_duplicate'))
        'Possible duplicate — FINVERSE will skip it if it already exists',
      if (row.flags.contains('ambiguous_date'))
        'Date interpreted from the statement format',
      if (row.flags.contains('recurring_payment')) 'Recurring pattern detected',
      if (incomplete) 'Incomplete row — it will be skipped without blocking approval',
    ];
    return Card(
      margin: const EdgeInsets.only(top: 8),
      child: ListTile(
        leading: Checkbox(
            value: _selected.contains(row.id),
            onChanged: row.decision == 'exclude'
                ? null
                : (checked) => setState(() => checked == true
                    ? _selected.add(row.id)
                    : _selected.remove(row.id))),
        title:
            Text(row.description, maxLines: 2, overflow: TextOverflow.ellipsis),
        subtitle: Text(
            '${row.postedAt ?? 'Date unavailable'} · ${row.amount ?? 'Amount unavailable'} ${row.currency} · ${row.direction}\n${row.merchant == null || row.merchant!.isEmpty ? row.description : row.merchant}\n$category · $categoryOrigin${row.categorySlug == 'unknown' ? '' : ' · ${(row.categoryConfidence * 100).round()}% confidence'}${notes.isEmpty ? '' : '\n${notes.join(' · ')}'}',
            style: TextStyle(
                color: incomplete ? theme.colorScheme.error : null)),
        isThreeLine: true,
        trailing: PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'edit') _editRow(row);
              if (value == 'category') _editCategory(row);
              if (value == 'include' || value == 'exclude') {
                _decision(row, value);
              }
              if (value == 'split') _split(row);
            },
            itemBuilder: (_) => const [
                  PopupMenuItem(value: 'edit', child: Text('Edit details')),
                  PopupMenuItem(value: 'include', child: Text('Include')),
                  PopupMenuItem(value: 'exclude', child: Text('Exclude')),
                  PopupMenuItem(value: 'category', child: Text('Recategorize')),
                  PopupMenuItem(value: 'split', child: Text('Split'))
                ]),
      ),
    );
  }

  Widget _summaryView(StatementSummary summary) => Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Wrap(spacing: 8, runSpacing: 8, children: [
            Chip(
                label: Text(
                    'Income ${_formatMinor(summary.income, summary.currency)}')),
            Chip(
                label: Text(
                    'Expenses ${_formatMinor(summary.expenses, summary.currency)}')),
            Chip(
                label: Text(
                    'Net cash flow ${_formatMinor(summary.netCashFlow, summary.currency)}')),
            Chip(
                label: Text(
                    'Savings ${_formatMinor(summary.savings, summary.currency)}')),
            Chip(label: Text('${summary.recurringCount} recurring')),
            if (summary.unusualCount > 0)
              Chip(label: Text('${summary.unusualCount} unusual')),
            if (summary.duplicateCount > 0)
              Chip(
                  label: Text('${summary.duplicateCount} possible duplicates')),
          ]),
          if (summary.categoryTotals.isNotEmpty) ...[
            const SizedBox(height: 8),
            const Text('Category totals',
                style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            ...summary.categoryTotals.map((category) => Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                          child: Text(
                              '${category['label']} (${category['count']})')),
                      Text(_formatMinor(
                          category['amount'] as int, summary.currency)),
                    ],
                  ),
                )),
          ],
        ]),
      );

  Widget _documentDetailsView(StatementDocumentDetails details) {
    final lines = <String>[
      if (details.issuer != null) 'Issuer: ${details.issuer}',
      if (details.accountReferenceLast4 != null)
        'Document account: ••••${details.accountReferenceLast4}',
      if (details.periodStart != null && details.periodEnd != null)
        'Statement period: ${details.periodStart} to ${details.periodEnd}',
      if (details.statementDate != null)
        'Statement date: ${details.statementDate}',
      if (details.currency != null) 'Document currency: ${details.currency}',
    ];
    if (lines.isEmpty) return const SizedBox.shrink();
    return Card(
      margin: const EdgeInsets.only(top: 12),
      child: ListTile(
        leading: const Icon(Icons.description_outlined),
        title: const Text('Document details'),
        subtitle: Text(lines.join('\n')),
      ),
    );
  }
}

String _formatMinor(int amount, String currency) =>
    '$currency ${(amount / 100).toStringAsFixed(2)}';

String _mimeFor(String name) {
  switch (name.toLowerCase().split('.').last) {
    case 'csv':
      return 'text/csv';
    case 'xlsx':
      return 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
    case 'pdf':
      return 'application/pdf';
    case 'png':
      return 'image/png';
    case 'jpg':
    case 'jpeg':
      return 'image/jpeg';
    case 'webp':
      return 'image/webp';
    case 'tiff':
      return 'image/tiff';
    case 'bmp':
      return 'image/bmp';
    default:
      return 'application/octet-stream';
  }
}
