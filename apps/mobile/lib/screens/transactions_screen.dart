import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/client.dart';
import '../design/design.dart';
import '../l10n/app_localizations.dart';
import '../models/models.dart';
import '../widgets/transaction_tile.dart';
import 'transaction_feed_groups.dart';
import 'transaction_detail_screen.dart';
import 'statement_import_screen.dart';
import 'manual_transaction_screen.dart';

class TransactionsScreen extends StatefulWidget {
  const TransactionsScreen({
    required this.api,
    this.initialCategorySlug,
    this.initialSearch,
    super.key,
  });

  final ApiClient api;
  final String? initialCategorySlug;
  final String? initialSearch;

  @override
  State<TransactionsScreen> createState() => _TransactionsScreenState();
}

class _TransactionsScreenState extends State<TransactionsScreen> {
  final _search = TextEditingController();
  final _scroll = ScrollController();
  List<Transaction> _rows = const [];
  List<CategoryDefinition> _categories = const [];
  List<Account> _accounts = const [];
  String? _nextCursor;
  String? _interpretation;
  bool _loading = true;
  bool _loadingMore = false;
  String? _error;
  Timer? _searchDebounce;
  String? _categorySlug;
  String? _accountId;
  String? _categoryKind;
  bool? _pending;
  bool? _recurring;
  int? _amountMin;
  int? _amountMax;
  DateTime? _from;
  DateTime? _to;
  int _loadGeneration = 0;

  @override
  void initState() {
    super.initState();
    _categorySlug = widget.initialCategorySlug;
    if (widget.initialSearch != null && widget.initialSearch!.isNotEmpty) {
      _search.text = widget.initialSearch!;
    }
    widget.api.dataRevision.addListener(_onDataChanged);
    _scroll.addListener(_onScroll);
    _load();
    _loadFilterOptions();
  }

  @override
  void dispose() {
    widget.api.dataRevision.removeListener(_onDataChanged);
    _search.dispose();
    _searchDebounce?.cancel();
    _scroll
      ..removeListener(_onScroll)
      ..dispose();
    super.dispose();
  }

  void _onDataChanged() {
    if (!mounted || _loading || _loadingMore) return;
    unawaited(_load());
  }

  Future<void> _loadFilterOptions() async {
    try {
      final result = await Future.wait<dynamic>([
        widget.api.categories(),
        widget.api.accounts(),
      ]);
      if (!mounted) return;
      setState(() {
        _categories = result[0] as List<CategoryDefinition>;
        _accounts = result[1] as List<Account>;
      });
    } catch (_) {
      // The feed remains useful without filter metadata; the sheet can still
      // filter by status, amount, and date while offline.
    }
  }

  void _onScroll() {
    if (_scroll.position.pixels >= _scroll.position.maxScrollExtent - 500) {
      _loadMore();
    }
  }

  Future<void> _load() async {
    final generation = ++_loadGeneration;
    widget.api.resetOfflineStatus();
    setState(() {
      _loading = true;
      _loadingMore = false;
      _error = null;
    });
    try {
      final page = await widget.api.transactionsPage(
        limit: 100,
        search: _search.text.trim(),
        accountId: _accountId,
        categorySlug: _categorySlug,
        categoryKind: _categoryKind,
        pending: _pending,
        recurring: _recurring,
        amountMin: _amountMin,
        amountMax: _amountMax,
        from: _from,
        to: _to,
      );
      if (mounted && generation == _loadGeneration) {
        setState(() {
          _rows = page.transactions;
          _nextCursor = page.nextCursor;
          _interpretation = page.interpretation;
        });
      }
    } catch (error) {
      if (mounted && generation == _loadGeneration) {
        setState(() => _error = friendlyErrorMessage(error));
      }
    } finally {
      if (mounted && generation == _loadGeneration) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _loadMore() async {
    if (_loading || _loadingMore || _nextCursor == null) return;
    final generation = _loadGeneration;
    setState(() => _loadingMore = true);
    try {
      final page = await widget.api.transactionsPage(
        limit: 100,
        search: _search.text.trim(),
        before: _nextCursor,
        accountId: _accountId,
        categorySlug: _categorySlug,
        categoryKind: _categoryKind,
        pending: _pending,
        recurring: _recurring,
        amountMin: _amountMin,
        amountMax: _amountMax,
        from: _from,
        to: _to,
      );
      if (!mounted || generation != _loadGeneration) return;
      final known = _rows.map((row) => row.id).toSet();
      setState(() {
        _rows = [
          ..._rows,
          ...page.transactions.where((row) => known.add(row.id)),
        ];
        _nextCursor = page.nextCursor;
      });
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(AppLocalizations.of(context)
              .transactionsLoadOlderFailed(friendlyErrorMessage(error))),
        ));
      }
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  void _onSearchChanged(String value) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 350), _load);
  }

  int get _activeFilterCount => [
        _categorySlug,
        _accountId,
        _categoryKind,
        _pending,
        _recurring,
        _amountMin,
        _amountMax,
        _from,
        _to,
      ].where((value) => value != null).length;

  Future<void> _openFilters() async {
    final selected = await showModalBottomSheet<_TransactionFilterValues>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => _TransactionFilterSheet(
        categories: _categories,
        accounts: _accounts,
        initial: _TransactionFilterValues(
          categorySlug: _categorySlug,
          accountId: _accountId,
          categoryKind: _categoryKind,
          pending: _pending,
          recurring: _recurring,
          amountMin: _amountMin,
          amountMax: _amountMax,
          from: _from,
          to: _to,
        ),
      ),
    );
    if (!mounted || selected == null) return;
    setState(() {
      _categorySlug = selected.categorySlug;
      _accountId = selected.accountId;
      _categoryKind = selected.categoryKind;
      _pending = selected.pending;
      _recurring = selected.recurring;
      _amountMin = selected.amountMin;
      _amountMax = selected.amountMax;
      _from = selected.from;
      _to = selected.to;
    });
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.transactionsTitle),
        actions: [
          IconButton(
            tooltip: 'Add income or expense',
            icon: const Icon(Icons.add),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => ManualTransactionScreen(api: widget.api),
            )),
          ),
          IconButton(
            tooltip: 'Import statement',
            icon: const Icon(Icons.upload_file_outlined),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => StatementImportScreen(api: widget.api),
            )),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: SearchBar(
              controller: _search,
              hintText: l10n.transactionsSearchHint,
              leading: const Icon(Icons.search),
              trailing: [
                IconButton(
                  tooltip: _activeFilterCount == 0
                      ? l10n.transactionsFilterAction
                      : l10n.transactionsFiltersActive(_activeFilterCount),
                  onPressed: _openFilters,
                  icon: Icon(_activeFilterCount == 0
                      ? Icons.filter_alt_outlined
                      : Icons.filter_alt),
                ),
                IconButton(
                  tooltip: l10n.transactionsSearchAction,
                  onPressed: _load,
                  icon: const Icon(Icons.arrow_forward),
                ),
              ],
              onChanged: _onSearchChanged,
              onSubmitted: (_) => _load(),
            ),
          ),
          if (_interpretation != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.auto_awesome_outlined, size: 16),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _interpretation!,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
          Expanded(child: _body()),
        ],
      ),
    );
  }

  Widget _body() {
    if (_loading) {
      return ListView(
        padding: EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [FinListSkeleton(rows: 7)],
      );
    }
    if (_error != null) {
      return Center(
          child: FilledButton(
              onPressed: _load,
              child:
                  Text(AppLocalizations.of(context).transactionsRetryAction)));
    }
    if (_rows.isEmpty) {
      return Center(
          child: Text(AppLocalizations.of(context).transactionsNoMatches));
    }
    final groups = groupTransactionsByDate(_rows);
    final items = <Object>[];
    for (final group in groups) {
      items
        ..add(group)
        ..addAll(group.transactions);
    }
    if (_loadingMore) items.add(const _LoadingMoreTransactions());

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.builder(
        controller: _scroll,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: items.length,
        itemBuilder: (context, index) {
          final item = items[index];
          if (item is TransactionDateGroup) {
            return Padding(
              key: ValueKey('transaction-date-${item.label}'),
              padding: const EdgeInsets.only(top: 16, bottom: 8),
              child: Semantics(
                header: true,
                child: Text(
                  item.label,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
              ),
            );
          }
          if (item is _LoadingMoreTransactions) {
            return const Padding(
              padding: EdgeInsets.all(20),
              child: Center(child: CircularProgressIndicator()),
            );
          }
          final row = item as Transaction;
          return TransactionTile(
            transaction: row,
            onTap: () async {
              await Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => TransactionDetailScreen(
                  api: widget.api,
                  transaction: row,
                ),
              ));
              await _load();
            },
            onRecategorize: (slug) async {
              await widget.api.recategorize(row.id, slug);
              await _load();
            },
          );
        },
      ),
    );
  }
}

class _LoadingMoreTransactions {
  const _LoadingMoreTransactions();
}

class _TransactionFilterValues {
  const _TransactionFilterValues({
    this.categorySlug,
    this.accountId,
    this.categoryKind,
    this.pending,
    this.recurring,
    this.amountMin,
    this.amountMax,
    this.from,
    this.to,
  });

  final String? categorySlug;
  final String? accountId;
  final String? categoryKind;
  final bool? pending;
  final bool? recurring;
  final int? amountMin;
  final int? amountMax;
  final DateTime? from;
  final DateTime? to;
}

class _TransactionFilterSheet extends StatefulWidget {
  const _TransactionFilterSheet({
    required this.categories,
    required this.accounts,
    required this.initial,
  });

  final List<CategoryDefinition> categories;
  final List<Account> accounts;
  final _TransactionFilterValues initial;

  @override
  State<_TransactionFilterSheet> createState() =>
      _TransactionFilterSheetState();
}

class _TransactionFilterSheetState extends State<_TransactionFilterSheet> {
  late String _categorySlug;
  late String _accountId;
  late String _categoryKind;
  late String _status;
  late String _recurrence;
  late DateTime? _from;
  late DateTime? _to;
  late TextEditingController _minAmount;
  late TextEditingController _maxAmount;
  String? _validation;

  @override
  void initState() {
    super.initState();
    _categorySlug = widget.initial.categorySlug ?? '';
    _accountId = widget.initial.accountId ?? '';
    _categoryKind = widget.initial.categoryKind ?? '';
    _status = widget.initial.pending == null
        ? ''
        : widget.initial.pending!
            ? 'pending'
            : 'posted';
    _recurrence = widget.initial.recurring == null
        ? ''
        : widget.initial.recurring!
            ? 'recurring'
            : 'one-off';
    _from = widget.initial.from;
    _to = widget.initial.to;
    _minAmount = TextEditingController(
      text: widget.initial.amountMin?.toString() ?? '',
    );
    _maxAmount = TextEditingController(
      text: widget.initial.amountMax?.toString() ?? '',
    );
  }

  @override
  void dispose() {
    _minAmount.dispose();
    _maxAmount.dispose();
    super.dispose();
  }

  Future<void> _pickDate({required bool start}) async {
    final current = start ? _from : _to;
    final picked = await showDatePicker(
      context: context,
      firstDate: DateTime(2000),
      lastDate: DateTime.now().add(const Duration(days: 365)),
      initialDate: current ?? DateTime.now(),
    );
    if (!mounted || picked == null) return;
    setState(() {
      if (start) {
        _from = picked;
      } else {
        _to = picked;
      }
    });
  }

  void _apply() {
    final min = _parseAmount(_minAmount.text);
    final max = _parseAmount(_maxAmount.text);
    if ((_minAmount.text.trim().isNotEmpty && min == null) ||
        (_maxAmount.text.trim().isNotEmpty && max == null)) {
      setState(() => _validation =
          AppLocalizations.of(context).transactionsInvalidAmounts);
      return;
    }
    if (min != null && max != null && min > max) {
      setState(() => _validation =
          AppLocalizations.of(context).transactionsAmountRangeInvalid);
      return;
    }
    if (_from != null && _to != null && _from!.isAfter(_to!)) {
      setState(() => _validation =
          AppLocalizations.of(context).transactionsDateRangeInvalid);
      return;
    }
    Navigator.of(context).pop(_TransactionFilterValues(
      categorySlug: _categorySlug.isEmpty ? null : _categorySlug,
      accountId: _accountId.isEmpty ? null : _accountId,
      categoryKind: _categoryKind.isEmpty ? null : _categoryKind,
      pending: _status.isEmpty ? null : _status == 'pending',
      recurring: _recurrence.isEmpty ? null : _recurrence == 'recurring',
      amountMin: min,
      amountMax: max,
      from: _from,
      to: _to,
    ));
  }

  int? _parseAmount(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return null;
    final parsed = int.tryParse(trimmed);
    if (parsed == null || parsed < 0) return null;
    return parsed;
  }

  String _dateLabel(DateTime? date) {
    final l10n = AppLocalizations.of(context);
    return date == null
        ? l10n.transactionsChooseDate
        : MaterialLocalizations.of(context).formatMediumDate(date);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          20,
          0,
          20,
          20 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(l10n.transactionsFilterTitle,
                  style: theme.textTheme.titleLarge),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                initialValue: _categoryKind,
                decoration:
                    InputDecoration(labelText: l10n.transactionsMoneyTypeLabel),
                items: [
                  DropdownMenuItem(
                      value: '', child: Text(l10n.transactionsAllTypes)),
                  DropdownMenuItem(
                      value: 'expense', child: Text(l10n.transactionsSpending)),
                  DropdownMenuItem(
                      value: 'income', child: Text(l10n.transactionsIncome)),
                  DropdownMenuItem(
                      value: 'transfer',
                      child: Text(l10n.transactionsTransfers)),
                ],
                onChanged: (value) =>
                    setState(() => _categoryKind = value ?? ''),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: _categorySlug,
                decoration:
                    InputDecoration(labelText: l10n.transactionsCategoryLabel),
                items: [
                  DropdownMenuItem(
                      value: '', child: Text(l10n.transactionsAllCategories)),
                  ...widget.categories.map((category) => DropdownMenuItem(
                        value: category.slug,
                        child: Text(category.name),
                      )),
                ],
                onChanged: (value) =>
                    setState(() => _categorySlug = value ?? ''),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: _accountId,
                decoration:
                    InputDecoration(labelText: l10n.transactionsAccountLabel),
                items: [
                  DropdownMenuItem(
                      value: '', child: Text(l10n.transactionsAllAccounts)),
                  ...widget.accounts.map((account) => DropdownMenuItem(
                        value: account.id,
                        child: Text('${account.name} ••${account.mask}'),
                      )),
                ],
                onChanged: (value) => setState(() => _accountId = value ?? ''),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      initialValue: _status,
                      decoration: InputDecoration(
                          labelText: l10n.transactionsStatusLabel),
                      items: [
                        DropdownMenuItem(
                            value: '', child: Text(l10n.transactionsAll)),
                        DropdownMenuItem(
                            value: 'posted',
                            child: Text(l10n.transactionsPosted)),
                        DropdownMenuItem(
                            value: 'pending',
                            child: Text(l10n.transactionsPending)),
                      ],
                      onChanged: (value) =>
                          setState(() => _status = value ?? ''),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      initialValue: _recurrence,
                      decoration: InputDecoration(
                          labelText: l10n.transactionsFrequencyLabel),
                      items: [
                        DropdownMenuItem(
                            value: '', child: Text(l10n.transactionsAll)),
                        DropdownMenuItem(
                            value: 'recurring',
                            child: Text(l10n.transactionsRecurring)),
                        DropdownMenuItem(
                            value: 'one-off',
                            child: Text(l10n.transactionsOneOff)),
                      ],
                      onChanged: (value) =>
                          setState(() => _recurrence = value ?? ''),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _minAmount,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      decoration: InputDecoration(
                        labelText: l10n.transactionsMinAmountLabel,
                        helperText: l10n.transactionsMinorUnits,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: _maxAmount,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      decoration: InputDecoration(
                        labelText: l10n.transactionsMaxAmountLabel,
                        helperText: l10n.transactionsMinorUnits,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => _pickDate(start: true),
                      icon: const Icon(Icons.calendar_today_outlined),
                      label: Text(l10n.transactionsFrom(_dateLabel(_from))),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => _pickDate(start: false),
                      icon: const Icon(Icons.calendar_today_outlined),
                      label: Text(l10n.transactionsTo(_dateLabel(_to))),
                    ),
                  ),
                ],
              ),
              if (_validation != null) ...[
                const SizedBox(height: 12),
                Text(_validation!,
                    style: TextStyle(color: theme.colorScheme.error)),
              ],
              const SizedBox(height: 20),
              Row(
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context)
                        .pop(const _TransactionFilterValues()),
                    child: Text(l10n.transactionsClearFilters),
                  ),
                  const Spacer(),
                  FilledButton(
                    onPressed: _apply,
                    child: Text(l10n.transactionsApplyFilters),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
