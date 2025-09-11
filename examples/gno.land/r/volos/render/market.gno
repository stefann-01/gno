package render

import (
	"net/url"
	"std"
	"strings"

	"gno.land/p/demo/avl"
	"gno.land/p/demo/avl/pager"
	"gno.land/p/demo/avl/rotree"
	"gno.land/p/moul/md"
	"gno.land/p/moul/mdtable"
	"gno.land/r/demo/grc20reg"
	"gno.land/r/sys/users"
	volos "gno.land/r/volos/core"
	"gno.land/p/volos/math"
	u256 "gno.land/p/gnoswap/uint256"
)

func renderMarketPage(path string) string {
	marketId := strings.TrimPrefix(path, "?market=")
	marketId = strings.SplitN(marketId, "&", 2)[0]
	if marketId == "" {
		return md.Paragraph("No market ID provided.")
	}

	marketId, _ = url.QueryUnescape(marketId)

	market, params := volos.GetMarket(marketId)

	loanPath := params.GetLoanToken()
	collateralPath := params.GetCollateralToken()
	loanToken := grc20reg.Get(loanPath)
	collateralToken := grc20reg.Get(collateralPath)

	loanSymbol := loanPath
	collateralSymbol := collateralPath
	if loanToken != nil {
		loanSymbol = loanToken.GetSymbol()
	}
	if collateralToken != nil {
		collateralSymbol = collateralToken.GetSymbol()
	}

	out := md.H1("🏦 " + loanSymbol + "/" + collateralSymbol + " Market")
	out += md.Paragraph("**Market ID:** " + md.InlineCode(marketId))

	out += md.H2("📊 Market Overview")
	overviewTable := mdtable.Table{
		Headers: []string{"Parameter", "Value"},
	}
	overviewTable.Append([]string{"Pool Path", md.InlineCode(params.PoolPath)})
	overviewTable.Append([]string{"Loan Token", loanSymbol + " (" + md.Link(loanPath, "/r/"+loanPath) + ")"})
	overviewTable.Append([]string{"Collateral Token", collateralSymbol + " (" + md.Link(collateralPath, "/r/"+collateralPath) + ")"})
	overviewTable.Append([]string{"Interest Rate Model", md.InlineCode(params.IRM)})
	overviewTable.Append([]string{"Liquidation LTV", formatPercentage(params.LLTV) + "%"})
	overviewTable.Append([]string{"Market Fee", market.Fee.ToString()})
	out += overviewTable.String()

	out += md.H2("💰 Market Statistics & Rates")
	statsTable := mdtable.Table{
		Headers: []string{"Metric", "Value", "Rate Type", "APR"},
	}

	borrowAPR := u256.MustFromDecimal(volos.GetBorrowAPR(marketId))
	supplyAPR := u256.MustFromDecimal(volos.GetSupplyAPR(marketId))
	totalSupplyAssets := market.TotalSupplyAssets
	totalBorrowAssets := market.TotalBorrowAssets
	utilization := volos.CalculateUtilization(marketId)

	statsTable.Append([]string{
		"Total Supply Assets", formatTokenAmount(totalSupplyAssets, loanToken.GetDecimals()),
		"Borrow Rate", formatPercentage(borrowAPR) + "%",
	})
	statsTable.Append([]string{
		"Total Borrow Assets", formatTokenAmount(totalBorrowAssets, loanToken.GetDecimals()),
		"Supply Rate", formatPercentage(supplyAPR) + "%",
	})
	statsTable.Append([]string{
		"Utilization Rate", formatPercentage(utilization) + "%",
		"Last Update", formatTimestamp(market.LastUpdate),
	})
	out += statsTable.String()

	out += md.H2("💱 Current Price")
	price := volos.GetMarketPrice(marketId)
	out += md.Paragraph("**Oracle Price:** " + price + " " + loanSymbol + " per " + collateralSymbol)
	out += md.Blockquote("Price sourced from Gnoswap pool: " + params.PoolPath)

	out += md.H2("👥 Top Positions")
	positions := volos.GetPositionList(marketId)
	if len(positions) == 0 {
		out += md.Paragraph("🦌 No positions in this market yet.")
	} else {
		positionsTree := avl.NewTree()
		for _, userAddr := range positions {
			positionsTree.Set(userAddr, userAddr)
		}

		positionPager := pager.NewPager(rotree.Wrap(positionsTree, nil), 5, false)
		positionPage := positionPager.MustGetPageByPath(path)

		positionsTable := mdtable.Table{
			Headers: []string{"User", "Supplied", "Borrowed", "Health Factor"},
		}

		for _, item := range positionPage.Items {
			userAddr := item.Key
			pos := volos.GetPosition(marketId, userAddr)
			if pos.SupplyShares.IsZero() && pos.BorrowShares.IsZero() && pos.Collateral.IsZero() {
				continue
			}

			usAddr := std.Address(userAddr)
			userData := users.ResolveAddress(usAddr)
			displayName := userAddr
			if userData != nil && userData.Name() != "" {
				displayName = userData.Name()
			}

			userLink := md.Link(displayName, "?user="+userAddr)
			supplied := math.ToAssetsUp(pos.SupplyShares, totalSupplyAssets, market.TotalSupplyShares)
			borrowed := math.ToAssetsUp(pos.BorrowShares, totalBorrowAssets, market.TotalBorrowShares)

			healthFactor := volos.GetHealthFactor(marketId, userAddr)

			hf := formatPercentage(u256.MustFromDecimal(healthFactor))
			hfString := hf
			if parseFloat(hf) < 1.5 {
				hfString = "⚠️ " + hf
			} else if parseFloat(hf) > 3.0 {
				hfString = "🔥 3.00+"
			}

			positionsTable.Append([]string{userLink, formatTokenAmount(supplied, loanToken.GetDecimals()), formatTokenAmount(borrowed, loanToken.GetDecimals()), hfString})
		}

		if len(positionsTable.Rows) > 0 {
			out += positionsTable.String()
			out += md.HorizontalRule()
			picker := positionPage.Picker(path)
			if picker != "" {
				out += md.Paragraph(picker)
			}
		} else {
			out += md.Paragraph("🦌 No active positions in this market.")
		}
	}

	return out
}
