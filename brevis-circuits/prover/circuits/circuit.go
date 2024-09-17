package age

import (
	"github.com/brevis-network/brevis-sdk/sdk"
)

type AppCircuit struct{}

func (c *AppCircuit) Allocate() (maxReceipts, maxStorage, maxTransactions int) {
	// Our app is only ever going to use one storage data at a time so
	// we can simply limit the max number of data for storage to 1 and
	// 0 for all others
	return 3, 0, 1
}

func (c *AppCircuit) Define(api *sdk.CircuitAPI, in sdk.DataInput) error {
	txs := sdk.NewDataStream(api, in.Transactions)
	events := sdk.NewDataStream(api, in.Receipts)

	tx := sdk.GetUnderlying(txs, 0)
	sdk.AssertEach(receipts, func(l sdk.Receipt) sdk.Uint248 {
		isTheSameBlock := api.Uint64.AssertIsEqual(tx.BlockNum, l.BlockNum)
		isTheSameSender := api.Address.AssertIsEqual(tx.From, l.From)
		return u248.and(isTheSameBlock, isTheSameSender,
			u248.IsEqual(l.Fields[0].Contract, ),
			u248.IsEqual(l.Fields[1].Contract, UsdcPoolAddress),
			u248.IsEqual(l.Fields[2].Contract, UsdcPoolAddress),
			u248.IsZero(l.Fields[0].IsTopic),                     // `amount0` is not a topic field
			u248.IsEqual(l.Fields[0].Index, sdk.ConstUint248(0)), // `amount0` is the 0th data field in the `Swap` event
			l.Fields[1].IsTopic,                                  // `recipient` is a topic field
			u248.IsEqual(l.Fields[1].Index, sdk.ConstUint248(2)), // `recipient` is the 2nd topic field in the `Swap` event
			l.Fields[2].IsTopic,                                  // `from` is a topic field
			u248.IsEqual(l.Fields[2].Index, sdk.ConstUint248(1)),)
	})

	sdk.AssertEqual(receipts.Length(), 1)



	// This is our main check logic
	api.Uint248.AssertIsEqual(tx.Nonce, sdk.ConstUint248(0))

	// Output variables can be later accessed in our app contract
	api.OutputAddress(tx.From)
	api.OutputUint(64, tx.BlockNum)

	return nil
}
