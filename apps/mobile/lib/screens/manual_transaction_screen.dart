import 'dart:math';
import 'package:flutter/material.dart';
import '../api/client.dart';
import '../models/models.dart';
import 'bank_connections_screen.dart';

/// Convert typed amounts using integer arithmetic and the server's currency scale.
int? parseManualAmount(String value, int exponent) {
  if (exponent < 0 || exponent > 4) return null;
  final match = RegExp(r'^(\d+)(?:\.(\d+))?$').firstMatch(value.trim());
  if (match == null) return null;
  final fraction = match.group(2) ?? '';
  if (fraction.length > exponent) return null;
  final digits = '${match.group(1)}${fraction.padRight(exponent, '0')}';
  final minor = int.tryParse(digits);
  return minor != null && minor > 0 && minor <= 10000000000000 ? minor : null;
}

class ManualTransactionScreen extends StatefulWidget {
  const ManualTransactionScreen({required this.api, super.key});
  final ApiClient api;
  @override
  State<ManualTransactionScreen> createState() =>
      _ManualTransactionScreenState();
}

class _ManualTransactionScreenState extends State<ManualTransactionScreen> {
  final _form = GlobalKey<FormState>();
  final _description = TextEditingController();
  final _amount = TextEditingController();
  final _requestId = List.generate(24, (_) => Random.secure().nextInt(256))
      .map((n) => n.toRadixString(16).padLeft(2, '0'))
      .join();
  List<Account> _accounts = [];
  List<CategoryDefinition> _categories = [];
  String? _accountId;
  String? _category;
  String? _error;
  bool _loading = true;
  bool _saving = false;
  bool _income = false;
  DateTime _date = DateTime.now();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _description.dispose();
    _amount.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final results = await Future.wait<dynamic>(
          [widget.api.accounts(), widget.api.categories()]);
      if (!mounted) return;
      setState(() {
        _accounts =
            (results[0] as List<Account>).where((a) => a.isManual).toList();
        _categories = results[1] as List<CategoryDefinition>;
        _accountId = _accounts.isEmpty ? null : _accounts.first.id;
      });
    } catch (error) {
      if (mounted) setState(() => _error = friendlyErrorMessage(error));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Account? get _account {
    for (final account in _accounts) {
      if (account.id == _accountId) return account;
    }
    return null;
  }

  Future<void> _save() async {
    if (_saving || !_form.currentState!.validate() || _account == null) return;
    final amount =
        parseManualAmount(_amount.text, _account!.minorUnitExponent)!;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.api.createManualTransaction(
        requestId: _requestId,
        accountId: _accountId!,
        postedAt:
            '${_date.year.toString().padLeft(4, '0')}-${_date.month.toString().padLeft(2, '0')}-${_date.day.toString().padLeft(2, '0')}',
        description: _description.text.trim(),
        categorySlug: _category!,
        amount: _income ? amount : -amount,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Transaction saved.')));
      Navigator.of(context).pop();
    } catch (error) {
      if (mounted) {
        setState(() => _error =
            '${friendlyErrorMessage(error)} Your entries are still here. Retry saving, or check Transactions if the connection dropped.');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final categories = _categories
        .where((c) => c.kind == (_income ? 'income' : 'expense'))
        .toList();
    return PopScope(
      canPop: !_saving,
      child: Scaffold(
        appBar: AppBar(title: const Text('Add income or expense')),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : Center(
                child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 600),
                child: ListView(padding: const EdgeInsets.all(20), children: [
                  if (_error != null) ...[
                    Semantics(
                        liveRegion: true,
                        child: Text(_error!,
                            style: TextStyle(
                                color: Theme.of(context).colorScheme.error))),
                    const SizedBox(height: 12),
                  ],
                  if (_accounts.isEmpty) ...[
                    const Text(
                        'Add a manual account to record cash spending or income.'),
                    const SizedBox(height: 12),
                    FilledButton(
                        onPressed: () async {
                          await Navigator.of(context).push(MaterialPageRoute(
                              builder: (_) =>
                                  BankConnectionsScreen(api: widget.api)));
                          if (mounted) await _load();
                        },
                        child: const Text('Manage accounts')),
                    TextButton(
                        onPressed: _load, child: const Text('Retry loading')),
                  ] else
                    Form(
                        key: _form,
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              const Text('Manual record',
                                  style:
                                      TextStyle(fontWeight: FontWeight.bold)),
                              const SizedBox(height: 8),
                              const Text(
                                  'This records actual income or spending in your reports. Account balances are snapshots; update the balance separately in Manage accounts.'),
                              const SizedBox(height: 20),
                              SegmentedButton<bool>(
                                segments: const [
                                  ButtonSegment(
                                      value: false,
                                      label: Text('Expense'),
                                      icon: Icon(Icons.arrow_upward)),
                                  ButtonSegment(
                                      value: true,
                                      label: Text('Income'),
                                      icon: Icon(Icons.arrow_downward)),
                                ],
                                selected: {_income},
                                onSelectionChanged: _saving
                                    ? null
                                    : (v) => setState(() {
                                          _income = v.first;
                                          _category = null;
                                        }),
                              ),
                              const SizedBox(height: 20),
                              DropdownButtonFormField<String>(
                                initialValue: _accountId,
                                isExpanded: true,
                                decoration: const InputDecoration(
                                    labelText: 'Manual account'),
                                items: _accounts
                                    .map((a) => DropdownMenuItem(
                                        value: a.id,
                                        child: Text('${a.name} (${a.currency})',
                                            overflow: TextOverflow.ellipsis)))
                                    .toList(),
                                onChanged: _saving
                                    ? null
                                    : (v) => setState(() => _accountId = v),
                                validator: (v) =>
                                    v == null ? 'Choose an account.' : null,
                              ),
                              const SizedBox(height: 16),
                              TextFormField(
                                controller: _amount,
                                enabled: !_saving,
                                decoration: InputDecoration(
                                    labelText:
                                        'Amount (${_account?.currency ?? ''})',
                                    helperText: 'Enter a positive amount.'),
                                keyboardType:
                                    const TextInputType.numberWithOptions(
                                        decimal: true),
                                validator: (v) => parseManualAmount(v ?? '',
                                            _account?.minorUnitExponent ?? 2) ==
                                        null
                                    ? 'Enter a positive amount with up to ${_account?.minorUnitExponent ?? 2} decimal places.'
                                    : null,
                              ),
                              const SizedBox(height: 16),
                              TextFormField(
                                controller: _description,
                                enabled: !_saving,
                                maxLength: 200,
                                textCapitalization:
                                    TextCapitalization.sentences,
                                decoration: const InputDecoration(
                                    labelText: 'Description',
                                    hintText:
                                        'Groceries, salary, or another payment'),
                                validator: (v) => v == null || v.trim().isEmpty
                                    ? 'Enter a description.'
                                    : null,
                              ),
                              const SizedBox(height: 8),
                              DropdownButtonFormField<String>(
                                key: ValueKey(_income),
                                initialValue: _category,
                                isExpanded: true,
                                decoration: const InputDecoration(
                                    labelText: 'Category'),
                                items: categories
                                    .map((c) => DropdownMenuItem(
                                        value: c.slug, child: Text(c.name)))
                                    .toList(),
                                onChanged: _saving
                                    ? null
                                    : (v) => setState(() => _category = v),
                                validator: (v) =>
                                    v == null ? 'Choose a category.' : null,
                              ),
                              const SizedBox(height: 16),
                              OutlinedButton.icon(
                                icon: const Icon(Icons.calendar_today),
                                label: Text(MaterialLocalizations.of(context)
                                    .formatMediumDate(_date)),
                                onPressed: _saving
                                    ? null
                                    : () async {
                                        final selected = await showDatePicker(
                                            context: context,
                                            initialDate: _date,
                                            firstDate: DateTime(1900),
                                            lastDate: DateTime.now());
                                        if (selected != null && mounted) {
                                          setState(() => _date = selected);
                                        }
                                      },
                              ),
                              const SizedBox(height: 24),
                              FilledButton.icon(
                                onPressed: _saving ? null : _save,
                                icon: _saving
                                    ? const SizedBox(
                                        width: 18,
                                        height: 18,
                                        child: CircularProgressIndicator(
                                            strokeWidth: 2))
                                    : const Icon(Icons.check),
                                label: Text(
                                    _saving ? 'Saving?' : 'Save transaction'),
                              ),
                            ])),
                ]),
              )),
      ),
    );
  }
}
