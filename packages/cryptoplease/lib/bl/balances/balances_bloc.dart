import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:cryptoplease/bl/amount.dart';
import 'package:cryptoplease/bl/processing_state.dart';
import 'package:cryptoplease/bl/solana_helpers.dart';
import 'package:cryptoplease/bl/tokens/token.dart';
import 'package:cryptoplease/bl/tokens/token_list.dart';
import 'package:dfunc/dfunc.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:logging/logging.dart';
import 'package:solana/dto.dart';
import 'package:solana/solana.dart';

part 'balances_bloc.freezed.dart';
part 'balances_event.dart';
part 'balances_state.dart';

final _logger = Logger('BalancesBloc');

class BalancesBloc extends Bloc<BalancesEvent, BalancesState> {
  BalancesBloc({
    required SolanaClient solanaClient,
    required TokenList tokens,
  })  : _solanaClient = solanaClient,
        _tokens = tokens,
        super(const BalancesState()) {
    on<BalancesEvent>(_eventHandler);
  }

  final SolanaClient _solanaClient;
  final TokenList _tokens;

  EventHandler<BalancesEvent, BalancesState> get _eventHandler =>
      (event, emit) => event.map(
            requested: (event) => _onRequested(event, emit),
          );

  Future<void> _onRequested(
    BalancesEventRequested event,
    Emitter<BalancesState> emit,
  ) async {
    if (state.processingState.isProcessing) return;

    final balances = <Token, Amount>{};

    try {
      emit(state.copyWith(processingState: const ProcessingState.processing()));
      balances[Token.sol] = await _solanaClient.getSolBalance(event.address);

      final allAccounts = await _solanaClient.getSplAccounts(
        event.address,
      );

      final mainAccounts = await Future.wait<_MainTokenAccount?>(
        allAccounts.map((programAccount) async {
          final pubKey = programAccount.pubkey;
          final account = programAccount.account;
          final data = account.data;

          if (data is ParsedAccountData) {
            return data.maybeWhen<Future<_MainTokenAccount?>>(
              splToken: (parsed) => parsed.maybeMap<Future<_MainTokenAccount?>>(
                account: (a) =>
                    _MainTokenAccount.create(pubKey, a.info, _tokens),
                orElse: () async => null,
              ),
              orElse: () async => null,
            );
          } else {
            return null;
          }
        }),
      ).then(compact);

      final tokenBalances = mainAccounts.map(
        (a) => MapEntry(
          a.token,
          Amount.fromToken(
            value: int.parse(a.info.tokenAmount.amount),
            token: a.token,
          ),
        ),
      );
      balances.addEntries(tokenBalances);

      emit(
        state.copyWith(
          processingState: const ProcessingState.none(),
          balances: balances.sorted,
        ),
      );
    } on Exception catch (exception) {
      _logger.severe('Failed to fetch balances', exception);

      emit(
        state.copyWith(
          processingState: ProcessingState.error(BalancesRequestException()),
        ),
      );
      emit(state.copyWith(processingState: const ProcessingState.none()));
    }
  }
}

class BalancesRequestException implements Exception {}

class _MainTokenAccount {
  const _MainTokenAccount._(this.pubKey, this.info, this.token);

  static Future<_MainTokenAccount?> create(
    String pubKey,
    SplTokenAccountDataInfo info,
    TokenList tokens,
  ) async {
    final expectedPubKey = await computeAssociatedTokenAccountAddress(
      owner: info.owner,
      mint: info.mint,
    );

    if (expectedPubKey != pubKey) return null;

    final token = tokens.findTokenByMint(info.mint);
    if (token == null) {
      // TODO(IA): we should find a way to display this
      return null;
    }

    return _MainTokenAccount._(pubKey, info, token);
  }

  final Token token;
  final SplTokenAccountDataInfo info;
  final String pubKey;
}

extension SortedBalance on Map<Token, Amount> {
  Iterable<MapEntry<Token, Amount>> _splitAndSort(
    bool Function(MapEntry<Token, Amount>) test,
  ) {
    final splitted = entries.where(test).toList()
      ..sort((e1, e2) => e2.value.value.compareTo(e1.value.value));

    return splitted;
  }

  Map<Token, Amount> get sorted {
    final geckoEntries = _splitAndSort((e) => e.key.coingeckoId != null);
    final notGeckoEntries = _splitAndSort((e) => e.key.coingeckoId == null);
    final sortedMap = Map.fromEntries(geckoEntries)
      ..addEntries(notGeckoEntries);

    return sortedMap;
  }
}

extension on SolanaClient {
  Future<Amount> getSolBalance(String address) async {
    final lamports = await rpcClient.getBalance(
      address,
      commitment: Commitment.confirmed,
    );

    return Amount.sol(value: lamports);
  }
}
