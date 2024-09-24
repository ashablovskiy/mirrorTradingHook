package tradingvolume

import (
	"github.com/brevis-network/brevis-sdk/sdk"
)

type AppCircuit struct {
	SubscriptionId sdk.Uint248
}

var _ sdk.AppCircuit = &AppCircuit{}

func (c *AppCircuit) Allocate() (maxReceipts, maxSlots, maxTransactions int) {
	return 1, 0, 0
}

func (c *AppCircuit) Define(api *sdk.CircuitAPI, in sdk.DataInput) error {

	// In order to use the nice methods such as .Map() and .Reduce(), raw data needs
	// to be wrapped in a DataStream. You could also use the raw data directly if you
	// are familiar with writing gnark circuits.
	receipts := sdk.NewDataStream(api, in.Receipts)
	receipt := sdk.GetUnderlying(receipts, 0)

	// check if the subscription id matches

	api.Uint248.AssertIsEqual(api.ToUint248(receipt.Fields[0].Value), c.SubscriptionId)

	api.OutputUint(248, api.ToUint248(receipt.Fields[2].Value))

	return nil
}
