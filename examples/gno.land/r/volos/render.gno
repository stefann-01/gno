package volos

import (
	"std"
	"strconv"
	"strings"

	"gno.land/p/demo/avl/pager"
	"gno.land/p/matijamarjanovic/charts"
	"gno.land/p/moul/md"
	"gno.land/p/moul/mdtable"
	"gno.land/r/demo/grc20reg"
	"gno.land/r/sys/users"
)

const pageSize = 10

func Render(path string) string {
	if path == "" || strings.HasPrefix(path, "?page=") {
		return renderHome(path)
	}
	if strings.HasPrefix(path, "?user=") {
		return renderUserPage(path)
	}
	// Future: handle market detail, etc.
	return md.Paragraph("Unknown page.")
}

func renderUserPage(path string) string {
	userAddr := strings.TrimPrefix(path, "?user=")
	userAddr = strings.SplitN(userAddr, "&", 2)[0]
	if userAddr == "" {
		return md.Paragraph("No user address provided.")
	}

	var displayName string
	usAddr := std.Address(userAddr)
	userData := users.ResolveAddress(usAddr)
	if userData != nil && userData.Name() != "" {
		displayName = userData.Name()
	} else {
		displayName = userAddr
	}

	out := md.H1("User Page")

	loans := GetUserLoans(userAddr)
	if len(loans) == 0 {
		out += md.Paragraph("No loans found for this address.")
		return out
	}

	var (
		labels []string
		values []float64
	)
	for i := 0; i < len(loans); i += 2 {
		tokenPath := loans[i]
		amountStr := loans[i+1]
		amount, err := strconv.ParseFloat(amountStr, 64)
		if err != nil {
			continue
		}
		token := grc20reg.Get(tokenPath)
		label := tokenPath
		if token != nil {
			label = token.GetSymbol()
		}
		labels = append(labels, label)
		values = append(values, amount)
	}

	chart := charts.GenerateBarChart(values, labels, 30, "Loans for "+displayName)
	out += chart

	// (Add more user info/sections here as needed)

	return out
}

func renderHome(path string) string {
	out := md.H1("Volos")
	out += md.H3("Lending Protocol")
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
