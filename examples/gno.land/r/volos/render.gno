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

func renderMarketPage(path string) string {
	marketId := strings.TrimPrefix(path, "?market=")
	marketId = strings.SplitN(marketId, "&", 2)[0]
	if marketId == "" {
		return md.Paragraph("No market ID provided.")
	}
	println("marketId", marketId) //needs to be decoded

	// Get market data
	market, params := GetMarket(marketId)
	
	// Get token information
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
	out += md.Paragraph("Market ID: " + md.InlineCode(marketId))
	
	// Market Overview Table
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
	
	// Market Statistics
	out += md.H2("💰 Market Statistics")
	statsTable := mdtable.Table{
		Headers: []string{"Metric", "Value"},
	}
	statsTable.Append([]string{"Total Supply Assets", FormatMoney(parseFloat(GetMarketTotalSupplyAssets(marketId)))})
	statsTable.Append([]string{"Total Supply Shares", GetMarketTotalSupplyShares(marketId)})
	statsTable.Append([]string{"Total Borrow Assets", FormatMoney(parseFloat(GetMarketTotalBorrowAssets(marketId)))})
	statsTable.Append([]string{"Total Borrow Shares", GetMarketTotalBorrowShares(marketId)})
	statsTable.Append([]string{"Utilization Rate", calculateUtilization(marketId) + "%"})
	statsTable.Append([]string{"Last Update", formatTimestamp(market.LastUpdate)})
	out += statsTable.String()
	
	// Interest Rates
	out += md.H2("📈 Interest Rates")
	ratesTable := mdtable.Table{
		Headers: []string{"Rate Type", "Per Second", "APR"},
	}
	borrowRate := GetBorrowRate(marketId)
	supplyRate := GetSupplyRate(marketId)
	borrowAPR := GetBorrowAPR(marketId)
	supplyAPR := GetSupplyAPR(marketId)
	
	ratesTable.Append([]string{"Borrow Rate", formatRate(borrowRate), formatRate(borrowAPR) + "%"})
	ratesTable.Append([]string{"Supply Rate", formatRate(supplyRate), formatRate(supplyAPR) + "%"})
	out += ratesTable.String()
	
	// Current Price
	out += md.H2("💱 Current Price")
	price := GetMarketPrice(marketId)
	out += md.Paragraph("**Oracle Price:** " + price + " " + loanSymbol + " per " + collateralSymbol)
	out += md.Blockquote("Price sourced from Gnoswap pool: " + params.PoolPath)
	
	// Top Positions
	out += md.H2("👥 Top Positions")
	positions := GetPositionList(marketId)
	if len(positions) == 0 {
		out += md.Paragraph("🦌 No positions in this market yet.")
	} else {
		// Create a simple tree from positions for pagination
		positionsTree := avl.NewTree()
		for _, userAddr := range positions {
			positionsTree.Set(userAddr, userAddr) // Use address as both key and value
		}
		
		// Create pager for positions
		positionPager := pager.NewPager(rotree.Wrap(positionsTree, nil), 10, false)
		positionPage := positionPager.MustGetPageByPath(path)
		
		positionsTable := mdtable.Table{
			Headers: []string{"User", "Supplied", "Borrowed", "Collateral", "Health Factor"},
		}
		
		for _, item := range positionPage.Items {
			userAddr := item.Key
			pos := GetPosition(marketId, userAddr)
			if pos.SupplyShares.IsZero() && pos.BorrowShares.IsZero() && pos.Collateral.IsZero() {
				continue
			}
			
			// Get user display name
			usAddr := std.Address(userAddr)
			userData := users.ResolveAddress(usAddr)
			displayName := userAddr
			if userData != nil && userData.Name() != "" {
				displayName = userData.Name()
			}
			
			userLink := md.Link(displayName, "?user="+userAddr)
			supplied := pos.SupplyShares.ToString()
			borrowed := pos.BorrowShares.ToString()
			collateral := pos.Collateral.ToString()
			healthFactor := GetHealthFactor(marketId, userAddr)
			
			positionsTable.Append([]string{userLink, supplied, borrowed, collateral, healthFactor})
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
	
	// Navigation
	out += md.H2("🔗 Navigation")
	out += md.Paragraph(md.Link("← Back to Markets", ""))
	out += md.Paragraph(md.Link("🏠 Home", ""))
	
	return out
}

// Helper functions
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
	// Convert from WAD-scaled to percentage
	percentage := rate * 100
	return strconv.FormatFloat(percentage, 'f', 4, 64)
}

func formatTimestamp(timestamp int64) string {
	// Simple timestamp formatting - could be enhanced with proper date formatting
	return strconv.FormatInt(timestamp, 10)
}
