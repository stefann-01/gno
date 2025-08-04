package volos

import (
	"net/url"
	"std"
	"strconv"
	"strings"
	"time"


	"gno.land/p/demo/avl/pager"
	"gno.land/p/matijamarjanovic/charts"
	"gno.land/p/moul/md"
	"gno.land/p/moul/mdtable"
	"gno.land/r/demo/grc20reg"
	"gno.land/r/sys/users"
	"gno.land/p/demo/avl/rotree"
	"gno.land/p/demo/avl"
)

const pageSize = 10

func Render(path string) string {
	if path == "" || strings.HasPrefix(path, "?page=") {
		return renderHome(path)
	}
	if strings.HasPrefix(path, "?user=") {
		return renderUserPage(path)
	}
	if strings.HasPrefix(path, "?market=") {
		return renderMarketPage(path)
	}
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

	out += md.H2("👤 Check Your Position")
	out += md.Blockquote("To view your lending and borrowing positions on Volos, navigate to `?user=g1xxx` e.g. `?user=g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5`")

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

func renderMarketPage(path string) string {
	marketId := strings.TrimPrefix(path, "?market=")
	marketId = strings.SplitN(marketId, "&", 2)[0]
	if marketId == "" {
		return md.Paragraph("No market ID provided.")
	}
	
	marketId, _ = url.QueryUnescape(marketId)

	market, params := GetMarket(marketId)
	
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
	overviewTable.Append([]string{"Loan Token", loanSymbol + " (" + md.InlineCode(loanPath) + ")"})
	overviewTable.Append([]string{"Collateral Token", collateralSymbol + " (" + md.InlineCode(collateralPath) + ")"})
	overviewTable.Append([]string{"Interest Rate Model", md.InlineCode(params.IRM)})
	overviewTable.Append([]string{"Liquidation LTV", params.LLTV.ToString() + "%"})
	overviewTable.Append([]string{"Market Fee", market.Fee.ToString()})
	out += overviewTable.String()
	
	out += md.H2("💰 Market Statistics & Rates")
	statsTable := mdtable.Table{
		Headers: []string{"Metric", "Value", "Rate Type", "APR"},
	}
	
	borrowAPR := GetBorrowAPR(marketId)
	supplyAPR := GetSupplyAPR(marketId)
	
	statsTable.Append([]string{
		"Total Supply Assets", FormatMoney(parseFloat(GetMarketTotalSupplyAssets(marketId))),
		"Borrow Rate", formatRate(borrowAPR) + "%",
	})
	statsTable.Append([]string{
		"Total Borrow Assets", FormatMoney(parseFloat(GetMarketTotalBorrowAssets(marketId))),
		"Supply Rate", formatRate(supplyAPR) + "%",
	})
	statsTable.Append([]string{
		"Utilization Rate", calculateUtilization(marketId) + "%",
		"Last Update", formatTimestamp(market.LastUpdate),
	})
	out += statsTable.String()
	
	out += md.H2("💱 Current Price")
	price := GetMarketPrice(marketId)
	out += md.Paragraph("**Oracle Price:** " + price + " " + loanSymbol + " per " + collateralSymbol)
	out += md.Blockquote("Price sourced from Gnoswap pool: " + params.PoolPath)
	
	out += md.H2("👥 Top Positions")
	positions := GetPositionList(marketId)
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
			pos := GetPosition(marketId, userAddr)
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
			supplied := pos.SupplyShares.ToString()
			borrowed := pos.BorrowShares.ToString()
			healthFactor := GetHealthFactor(marketId, userAddr)
			
			hfFloat, _ := strconv.ParseFloat(healthFactor, 64)
			if hfFloat < 1.0 {
				healthFactor = "⚠️ " + healthFactor
			}
			
			positionsTable.Append([]string{userLink, supplied, borrowed, healthFactor})
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
	
	out += md.HorizontalRule()
	out += md.Paragraph(md.Link("← Back to Markets", "") + " | " + md.Link("🏠 Home", ""))
	
	return out
}

func parseFloat(s string) float64 {
	f, _ := strconv.ParseFloat(s, 64)
	return f
}

func calculateUtilization(marketId string) string {
	totalSupply := parseFloat(GetMarketTotalSupplyAssets(marketId))
	totalBorrow := parseFloat(GetMarketTotalBorrowAssets(marketId))
	
	if totalSupply == 0 {
		return "0.00"
	}
	
	utilization := (totalBorrow / totalSupply) * 100
	return strconv.FormatFloat(utilization, 'f', 2, 64)
}

func formatRate(rateStr string) string {
	rate := parseFloat(rateStr)
	percentage := rate * 100
	return strconv.FormatFloat(percentage, 'f', 4, 64)
}

func formatTimestamp(timestamp int64) string {
	t := time.Unix(timestamp, 0)
	return t.Format("02 Jan 2006, 15:04:05")
}
