/// This module provides an interface to burn or collect and redistribute transaction fees.
module nabob_framework::transaction_fee {
    use nabob_framework::coin::{Self, AggregatableCoin, BurnCapability, MintCapability};
    use nabob_framework::nabob_account;
    use nabob_framework::nabob_coin::NabobCoin;
    use nabob_framework::fungible_asset::BurnRef;
    use nabob_framework::system_addresses;
    use std::error;
    use std::features;
    use std::option::{Self, Option};
    use std::signer;
    use nabob_framework::event;

    friend nabob_framework::block;
    friend nabob_framework::genesis;
    friend nabob_framework::reconfiguration;
    friend nabob_framework::transaction_validation;

    /// Gas fees are already being collected and the struct holding
    /// information about collected amounts is already published.
    const EALREADY_COLLECTING_FEES: u64 = 1;

    /// The burn percentage is out of range [0, 100].
    const EINVALID_BURN_PERCENTAGE: u64 = 3;

    /// No longer supported.
    const ENO_LONGER_SUPPORTED: u64 = 4;

    const EFA_GAS_CHARGING_NOT_ENABLED: u64 = 5;

    /// Stores burn capability to burn the gas fees.
    struct NabobCoinCapabilities has key {
        burn_cap: BurnCapability<NabobCoin>,
    }

    /// Stores burn capability to burn the gas fees.
    struct NabobFABurnCapabilities has key {
        burn_ref: BurnRef,
    }

    /// Stores mint capability to mint the refunds.
    struct NabobCoinMintCapability has key {
        mint_cap: MintCapability<NabobCoin>,
    }

    #[event]
    /// Breakdown of fee charge and refund for a transaction.
    /// The structure is:
    ///
    /// - Net charge or refund (not in the statement)
    ///    - total charge: total_charge_gas_units, matches `gas_used` in the on-chain `TransactionInfo`.
    ///      This is the sum of the sub-items below. Notice that there's potential precision loss when
    ///      the conversion between internal and external gas units and between native token and gas
    ///      units, so it's possible that the numbers don't add up exactly. -- This number is the final
    ///      charge, while the break down is merely informational.
    ///        - gas charge for execution (CPU time): `execution_gas_units`
    ///        - gas charge for IO (storage random access): `io_gas_units`
    ///        - storage fee charge (storage space): `storage_fee_octas`, to be included in
    ///          `total_charge_gas_unit`, this number is converted to gas units according to the user
    ///          specified `gas_unit_price` on the transaction.
    ///    - storage deletion refund: `storage_fee_refund_octas`, this is not included in `gas_used` or
    ///      `total_charge_gas_units`, the net charge / refund is calculated by
    ///      `total_charge_gas_units` * `gas_unit_price` - `storage_fee_refund_octas`.
    ///
    /// This is meant to emitted as a module event.
    struct FeeStatement has drop, store {
        /// Total gas charge.
        total_charge_gas_units: u64,
        /// Execution gas charge.
        execution_gas_units: u64,
        /// IO gas charge.
        io_gas_units: u64,
        /// Storage fee charge.
        storage_fee_octas: u64,
        /// Storage fee refund.
        storage_fee_refund_octas: u64,
    }

    /// Burn transaction fees in epilogue.
    public(friend) fun burn_fee(account: address, fee: u64) acquires NabobFABurnCapabilities, NabobCoinCapabilities {
        if (exists<NabobFABurnCapabilities>(@nabob_framework)) {
            let burn_ref = &borrow_global<NabobFABurnCapabilities>(@nabob_framework).burn_ref;
            nabob_account::burn_from_fungible_store(burn_ref, account, fee);
        } else {
            let burn_cap = &borrow_global<NabobCoinCapabilities>(@nabob_framework).burn_cap;
            if (features::operations_default_to_fa_bos_store_enabled()) {
                let (burn_ref, burn_receipt) = coin::get_paired_burn_ref(burn_cap);
                nabob_account::burn_from_fungible_store(&burn_ref, account, fee);
                coin::return_paired_burn_ref(burn_ref, burn_receipt);
            } else {
                coin::burn_from<NabobCoin>(
                    account,
                    fee,
                    burn_cap,
                );
            };
        };
    }

    /// Mint refund in epilogue.
    public(friend) fun mint_and_refund(account: address, refund: u64) acquires NabobCoinMintCapability {
        let mint_cap = &borrow_global<NabobCoinMintCapability>(@nabob_framework).mint_cap;
        let refund_coin = coin::mint(refund, mint_cap);
        coin::force_deposit(account, refund_coin);
    }

    /// Only called during genesis.
    public(friend) fun store_nabob_coin_burn_cap(nabob_framework: &signer, burn_cap: BurnCapability<NabobCoin>) {
        system_addresses::assert_nabob_framework(nabob_framework);

        if (features::operations_default_to_fa_bos_store_enabled()) {
            let burn_ref = coin::convert_and_take_paired_burn_ref(burn_cap);
            move_to(nabob_framework, NabobFABurnCapabilities { burn_ref });
        } else {
            move_to(nabob_framework, NabobCoinCapabilities { burn_cap })
        }
    }

    public entry fun convert_to_nabob_fa_burn_ref(nabob_framework: &signer) acquires NabobCoinCapabilities {
        assert!(features::operations_default_to_fa_bos_store_enabled(), EFA_GAS_CHARGING_NOT_ENABLED);
        system_addresses::assert_nabob_framework(nabob_framework);
        let NabobCoinCapabilities {
            burn_cap,
        } = move_from<NabobCoinCapabilities>(signer::address_of(nabob_framework));
        let burn_ref = coin::convert_and_take_paired_burn_ref(burn_cap);
        move_to(nabob_framework, NabobFABurnCapabilities { burn_ref });
    }

    /// Only called during genesis.
    public(friend) fun store_nabob_coin_mint_cap(nabob_framework: &signer, mint_cap: MintCapability<NabobCoin>) {
        system_addresses::assert_nabob_framework(nabob_framework);
        move_to(nabob_framework, NabobCoinMintCapability { mint_cap })
    }

    // Called by the VM after epilogue.
    fun emit_fee_statement(fee_statement: FeeStatement) {
        event::emit(fee_statement)
    }

    // DEPRECATED section:

    #[deprecated]
    /// DEPRECATED: Stores information about the block proposer and the amount of fees
    /// collected when executing the block.
    struct CollectedFeesPerBlock has key {
        amount: AggregatableCoin<NabobCoin>,
        proposer: Option<address>,
        burn_percentage: u8,
    }

    #[deprecated]
    /// DEPRECATED
    public fun initialize_fee_collection_and_distribution(_nabob_framework: &signer, _burn_percentage: u8) {
        abort error::not_implemented(ENO_LONGER_SUPPORTED)
    }

    #[deprecated]
    /// DEPRECATED
    public fun upgrade_burn_percentage(
        _nabob_framework: &signer,
        _new_burn_percentage: u8
    ) {
        abort error::not_implemented(ENO_LONGER_SUPPORTED)
    }

    #[deprecated]
    public fun initialize_storage_refund(_: &signer) {
        abort error::not_implemented(ENO_LONGER_SUPPORTED)
    }
}
