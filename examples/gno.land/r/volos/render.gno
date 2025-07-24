package volos

import (
	"gno.land/p/moul/md"
	"gno.land/p/demo/avl/pager"
	"gno.land/p/moul/mdtable"
	"gno.land/r/demo/grc20reg"
	"strings"
)

const pageSize = 10

func Render(path string) string {
	if path == "" || strings.HasPrefix(path, "?page=") || strings.HasPrefix(path, "?") {
		return renderHome(path)
	}
	// Future: handle market detail, etc.
	return md.Paragraph("Unknown page.")
}

func renderHome(path string) string {
	out := md.H1("Volos Lending Protocol")
	out += md.Paragraph("Volos is a decentralized lending protocol built on gno.land. It enables users to lend and borrow assets through configurable markets, with real-time risk management and on-chain price oracles powered by Gnoswap pools. The protocol uses a shares-based accounting system, supports variable interest rates, and ensures solvency through continuous health monitoring and liquidation mechanisms—all within the gno.land ecosystem.")
	
	pager := pager.NewPager(markets, pageSize, false)
	page := pager.MustGetPageByPath(path)

	out += md.H2("Markets")
	out += md.Paragraph("Browse all lending markets on Volos. Each market is defined by a Gnoswap pool, interest rate model, and collateralization parameters.")

	table := mdtable.Table{
		Headers: []string{"Loan Token", "Collateral Token", "IRM", "Total Borrow Assets", "Total Supply Assets", "LLTV", ""},
	}
	for _, item := range page.Items {
		marketId := item.Key
		_, params := GetMarket(marketId)
		loanPath := params.GetLoanToken()
		collateralPath := params.GetCollateralToken()
		irm := params.IRM
		lltv := params.LLTV.ToString()

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

		totalBorrowAssets := GetMarketTotalBorrowAssets(marketId)
		totalSupplyAssets := GetMarketTotalSupplyAssets(marketId)

		viewLink := md.Link("View", "?market="+marketId)
		table.Append([]string{loanSymbol, collateralSymbol, irm, totalBorrowAssets, totalSupplyAssets, lltv, viewLink})
	}

	if len(table.Rows) == 0 {
		out += md.Italic("No markets have been created yet.")
	} else {
		out += table.String()
		out += md.HorizontalRule()
		picker := page.Picker(path)
		if picker != "" {
			out += md.Paragraph(picker)
		}
	}

	return out
}
