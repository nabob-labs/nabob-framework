/// This module defines a minimal and generic Coin and Balance.
/// modified from https://github.com/move-language/move/tree/main/language/documentation/tutorial
module nabob_framework::nabob_coin {
    use std::error;
    use std::signer;
    use std::string;
    use std::vector;
    use std::option::{Self, Option};

    use nabob_framework::coin::{Self, BurnCapability, MintCapability};
    use nabob_framework::system_addresses;

    friend nabob_framework::genesis;

    /// Account does not have mint capability
    const ENO_CAPABILITIES: u64 = 1;
    /// Mint capability has already been delegated to this specified address
    const EALREADY_DELEGATED: u64 = 2;
    /// Cannot find delegation of mint capability to this account
    const EDELEGATION_NOT_FOUND: u64 = 3;

    struct NabobCoin has key {}

    struct MintCapStore has key {
        mint_cap: MintCapability<NabobCoin>,
    }

    /// Delegation token created by delegator and can be claimed by the delegatee as MintCapability.
    struct DelegatedMintCapability has store {
        to: address
    }

    /// The container stores the current pending delegations.
    struct Delegations has key {
        inner: vector<DelegatedMintCapability>,
    }

    /// Can only called during genesis to initialize the Nabob coin.
    public(friend) fun initialize(nabob_framework: &signer): (BurnCapability<NabobCoin>, MintCapability<NabobCoin>) {
        system_addresses::assert_nabob_framework(nabob_framework);

        let (burn_cap, freeze_cap, mint_cap) = coin::initialize_with_parallelizable_supply<NabobCoin>(
            nabob_framework,
            string::utf8(b"Nabob Coin"),
            string::utf8(b"APT"),
            8, // decimals
            true, // monitor_supply
        );

        // Nabob framework needs mint cap to mint coins to initial validators. This will be revoked once the validators
        // have been initialized.
        move_to(nabob_framework, MintCapStore { mint_cap });

        coin::destroy_freeze_cap(freeze_cap);
        (burn_cap, mint_cap)
    }

    public fun has_mint_capability(account: &signer): bool {
        exists<MintCapStore>(signer::address_of(account))
    }

    /// Only called during genesis to destroy the nabob framework account's mint capability once all initial validators
    /// and accounts have been initialized during genesis.
    public(friend) fun destroy_mint_cap(nabob_framework: &signer) acquires MintCapStore {
        system_addresses::assert_nabob_framework(nabob_framework);
        let MintCapStore { mint_cap } = move_from<MintCapStore>(@nabob_framework);
        coin::destroy_mint_cap(mint_cap);
    }

    /// Can only be called during genesis for tests to grant mint capability to nabob framework and core resources
    /// accounts.
    /// Expects account and APT store to be registered before calling.
    public(friend) fun configure_accounts_for_test(
        nabob_framework: &signer,
        core_resources: &signer,
        mint_cap: MintCapability<NabobCoin>,
    ) {
        system_addresses::assert_nabob_framework(nabob_framework);

        // Mint the core resource account NabobCoin for gas so it can execute system transactions.
        let coins = coin::mint<NabobCoin>(
            18446744073709551615,
            &mint_cap,
        );
        coin::deposit<NabobCoin>(signer::address_of(core_resources), coins);

        move_to(core_resources, MintCapStore { mint_cap });
        move_to(core_resources, Delegations { inner: vector::empty() });
    }

    /// Only callable in tests and testnets where the core resources account exists.
    /// Create new coins and deposit them into dst_addr's account.
    public entry fun mint(
        account: &signer,
        dst_addr: address,
        amount: u64,
    ) acquires MintCapStore {
        let account_addr = signer::address_of(account);

        assert!(
            exists<MintCapStore>(account_addr),
            error::not_found(ENO_CAPABILITIES),
        );

        let mint_cap = &borrow_global<MintCapStore>(account_addr).mint_cap;
        let coins_minted = coin::mint<NabobCoin>(amount, mint_cap);
        coin::deposit<NabobCoin>(dst_addr, coins_minted);
    }

    /// Only callable in tests and testnets where the core resources account exists.
    /// Create delegated token for the address so the account could claim MintCapability later.
    public entry fun delegate_mint_capability(account: signer, to: address) acquires Delegations {
        system_addresses::assert_core_resource(&account);
        let delegations = &mut borrow_global_mut<Delegations>(@core_resources).inner;
        vector::for_each_ref(delegations, |element| {
            let element: &DelegatedMintCapability = element;
            assert!(element.to != to, error::invalid_argument(EALREADY_DELEGATED));
        });
        vector::push_back(delegations, DelegatedMintCapability { to });
    }

    /// Only callable in tests and testnets where the core resources account exists.
    /// Claim the delegated mint capability and destroy the delegated token.
    public entry fun claim_mint_capability(account: &signer) acquires Delegations, MintCapStore {
        let maybe_index = find_delegation(signer::address_of(account));
        assert!(option::is_some(&maybe_index), EDELEGATION_NOT_FOUND);
        let idx = *option::borrow(&maybe_index);
        let delegations = &mut borrow_global_mut<Delegations>(@core_resources).inner;
        let DelegatedMintCapability { to: _ } = vector::swap_remove(delegations, idx);

        // Make a copy of mint cap and give it to the specified account.
        let mint_cap = borrow_global<MintCapStore>(@core_resources).mint_cap;
        move_to(account, MintCapStore { mint_cap });
    }

    fun find_delegation(addr: address): Option<u64> acquires Delegations {
        let delegations = &borrow_global<Delegations>(@core_resources).inner;
        let i = 0;
        let len = vector::length(delegations);
        let index = option::none();
        while (i < len) {
            let element = vector::borrow(delegations, i);
            if (element.to == addr) {
                index = option::some(i);
                break
            };
            i = i + 1;
        };
        index
    }

    #[test_only]
    use nabob_framework::account;
    #[test_only]
    use nabob_framework::aggregator_factory;
    #[test_only]
    use nabob_framework::fungible_asset::FungibleAsset;

    #[test_only]
    public fun mint_bob_fa_for_test(amount: u64): FungibleAsset acquires MintCapStore {
        ensure_initialized_with_bob_fa_metadata_for_test();
        coin::coin_to_fungible_asset(
            coin::mint(
                amount,
                &borrow_global<MintCapStore>(@nabob_framework).mint_cap
            )
        )
    }

    #[test_only]
    public fun ensure_initialized_with_bob_fa_metadata_for_test() {
        let nabob_framework = account::create_signer_for_test(@nabob_framework);
        if (!exists<MintCapStore>(@nabob_framework)) {
            if (!aggregator_factory::aggregator_factory_exists_for_testing()) {
                aggregator_factory::initialize_aggregator_factory_for_test(&nabob_framework);
            };
            let (burn_cap, mint_cap) = initialize(&nabob_framework);
            coin::destroy_burn_cap(burn_cap);
            coin::destroy_mint_cap(mint_cap);
        };
        coin::create_coin_conversion_map(&nabob_framework);
        coin::create_pairing<NabobCoin>(&nabob_framework);
    }

    #[test_only]
    public fun initialize_for_test(nabob_framework: &signer): (BurnCapability<NabobCoin>, MintCapability<NabobCoin>) {
        aggregator_factory::initialize_aggregator_factory_for_test(nabob_framework);
        let (burn_cap, mint_cap) = initialize(nabob_framework);
        coin::create_coin_conversion_map(nabob_framework);
        coin::create_pairing<NabobCoin>(nabob_framework);
        (burn_cap, mint_cap)
    }

    // This is particularly useful if the aggregator_factory is already initialized via another call path.
    #[test_only]
    public fun initialize_for_test_without_aggregator_factory(
        nabob_framework: &signer
    ): (BurnCapability<NabobCoin>, MintCapability<NabobCoin>) {
        let (burn_cap, mint_cap) = initialize(nabob_framework);
        coin::create_coin_conversion_map(nabob_framework);
        coin::create_pairing<NabobCoin>(nabob_framework);
        (burn_cap, mint_cap)
    }
}