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

	out := md.H1("👤 User Page")

	markets := GetUserMarkets(userAddr)
	loans := GetUserLoans(userAddr)

	if len(markets) == 0 && len(loans) == 0 {
		out += md.Paragraph("🦌 This user has no positions or loans in any market.")
		return out
	}

	totalSupplied := 0.0
	totalBorrowed := 0.0

	table := mdtable.Table{
		Headers: []string{"Market", "Supplied", "Borrowed", "Collateral", "Health Factor"},
	}

	anyRisk := false

	for _, marketId := range markets {
		pos := GetPosition(marketId, userAddr)
		_, params := GetMarket(marketId)
		loanToken := grc20reg.Get(params.GetLoanToken())
		collateralToken := grc20reg.Get(params.GetCollateralToken())
		marketLabel := marketId
		if loanToken != nil && collateralToken != nil {
			marketLabel = loanToken.GetSymbol() + "/" + collateralToken.GetSymbol()
		}
		marketLink := md.Link(marketLabel, "?market="+marketId)
		supplied := pos.SupplyShares.ToString()
		borrowed := pos.BorrowShares.ToString()
		collateral := pos.Collateral.ToString()
		hf := GetHealthFactor(marketId, userAddr)

		suppliedF, _ := strconv.ParseFloat(supplied, 64)
		borrowedF, _ := strconv.ParseFloat(borrowed, 64)
		hfF, _ := strconv.ParseFloat(hf, 64)
		totalSupplied += suppliedF
		totalBorrowed += borrowedF
		if hfF < 1.0 {
			anyRisk = true
		}
		table.Append([]string{marketLink, supplied, borrowed, collateral, hf})
	}

	if len(markets) > 0 {
		out += md.H2("📈 Positions")
		out += table.String()
		out += "\n"
		out += md.Blockquote("These fiat values are mocked: 1 token denom = $1.")
		out += "\n"
		out += md.Paragraph("💰 **Total Supplied:** $" + FormatMoney(totalSupplied))
		out += md.Paragraph("💰 **Total Borrowed:** $" + FormatMoney(totalBorrowed))
		if anyRisk {
			out += md.Paragraph("⚠️ " + md.Bold("Warning: One or more positions are at risk of liquidation!"))
		}
	}

	if len(loans) > 0 {
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
		out += md.H2("📊 Loans by Token")
		out += chart
	}

	return out
}

func renderHome(path string) string {
	out := md.H1("Volos🦌")
	out += md.Paragraph("Volos is a decentralized lending protocol built on gno.land. It enables users to lend and borrow assets through configurable markets, with real-time risk management and on-chain price oracles powered by Gnoswap pools. The protocol uses a shares-based accounting system, supports variable interest rates, and ensures solvency through continuous health monitoring and liquidation mechanisms—all within the gno.land ecosystem.")

	pager := pager.NewPager(markets, pageSize, false)
	page := pager.MustGetPageByPath(path)

	out += md.H2("📊 Markets")
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
		out += md.Italic("No markets have been created yet. 🦌")
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
