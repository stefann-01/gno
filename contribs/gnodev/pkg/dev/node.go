package dev

import (
	"context"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
	"unicode"

	"github.com/gnolang/gno/contribs/gnodev/pkg/emitter"
	"github.com/gnolang/gno/contribs/gnodev/pkg/events"
	"github.com/gnolang/gno/gno.land/pkg/gnoland"
	"github.com/gnolang/gno/gno.land/pkg/gnoland/ugnot"
	"github.com/gnolang/gno/gno.land/pkg/integration"
	"github.com/gnolang/gno/gnovm/pkg/gnomod"
	"github.com/gnolang/gno/tm2/pkg/amino"
	tmcfg "github.com/gnolang/gno/tm2/pkg/bft/config"
	"github.com/gnolang/gno/tm2/pkg/bft/node"
	"github.com/gnolang/gno/tm2/pkg/bft/rpc/client"
	bft "github.com/gnolang/gno/tm2/pkg/bft/types"
	"github.com/gnolang/gno/tm2/pkg/crypto"
	tm2events "github.com/gnolang/gno/tm2/pkg/events"
	"github.com/gnolang/gno/tm2/pkg/log"
	"github.com/gnolang/gno/tm2/pkg/sdk"
	"github.com/gnolang/gno/tm2/pkg/std"
	// backup "github.com/gnolang/tx-archive/backup/client"
	// restore "github.com/gnolang/tx-archive/restore/client"
)

type NodeConfig struct {
	Logger                *slog.Logger
	DefaultDeployer       crypto.Address
	BalancesList          []gnoland.Balance
	PackagesPathList      []PackagePath
	Emitter               emitter.Emitter
	InitialTxs            []gnoland.TxWithMetadata
	TMConfig              *tmcfg.Config
	SkipFailingGenesisTxs bool
	NoReplay              bool
	MaxGasPerBlock        int64
	ChainID               string
	ChainDomain           string
}

func DefaultNodeConfig(rootdir, domain string) *NodeConfig {
	tmc := gnoland.NewDefaultTMConfig(rootdir)
	tmc.Consensus.SkipTimeoutCommit = false // avoid time drifting, see issue #1507
	tmc.Consensus.WALDisabled = true
	tmc.Consensus.CreateEmptyBlocks = false

	defaultDeployer := crypto.MustAddressFromString(integration.DefaultAccount_Address)
	balances := []gnoland.Balance{
		{
			Address: defaultDeployer,
			Amount:  std.Coins{std.NewCoin(ugnot.Denom, 10e12)},
		},
	}

	return &NodeConfig{
		Logger:                log.NewNoopLogger(),
		Emitter:               &emitter.NoopServer{},
		DefaultDeployer:       defaultDeployer,
		BalancesList:          balances,
		ChainID:               tmc.ChainID(),
		ChainDomain:           domain,
		TMConfig:              tmc,
		SkipFailingGenesisTxs: true,
		MaxGasPerBlock:        10_000_000_000,
	}
}

// Node is not thread safe
type Node struct {
	*node.Node
	muNode sync.RWMutex

	config  *NodeConfig
	emitter emitter.Emitter
	client  client.Client
	logger  *slog.Logger
	pkgs    PackagesMap // path -> pkg

	// keep track of number of loaded package to be able to skip them on restore
	loadedPackages int

	// track starting time for genesis
	startTime time.Time

	// state
	initialState, state []gnoland.TxWithMetadata
	currentStateIndex   int
}

var DefaultFee = std.NewFee(50000, std.MustParseCoin(ugnot.ValueString(1000000)))

func NewDevNode(ctx context.Context, cfg *NodeConfig) (*Node, error) {
	mpkgs, err := NewPackagesMap(cfg.PackagesPathList)
	if err != nil {
		return nil, fmt.Errorf("unable map pkgs list: %w", err)
	}

	startTime := time.Now()
	pkgsTxs, err := mpkgs.Load(DefaultFee, startTime)
	if err != nil {
		return nil, fmt.Errorf("unable to load genesis packages: %w", err)
	}
	cfg.Logger.Info("pkgs loaded", "path", cfg.PackagesPathList)

	devnode := &Node{
		config:            cfg,
		client:            client.NewLocal(),
		emitter:           cfg.Emitter,
		pkgs:              mpkgs,
		logger:            cfg.Logger,
		loadedPackages:    len(pkgsTxs),
		startTime:         startTime,
		state:             cfg.InitialTxs,
		initialState:      cfg.InitialTxs,
		currentStateIndex: len(cfg.InitialTxs),
	}
	genesis := gnoland.DefaultGenState()
	genesis.Balances = cfg.BalancesList
	genesis.Txs = append(pkgsTxs, cfg.InitialTxs...)

	if err := devnode.rebuildNode(ctx, genesis); err != nil {
		return nil, fmt.Errorf("unable to initialize the node: %w", err)
	}

	return devnode, nil
}

func (n *Node) Close() error {
	n.muNode.Lock()
	defer n.muNode.Unlock()

	return n.Node.Stop()
}

func (n *Node) ListPkgs() []gnomod.Pkg {
	n.muNode.RLock()
	defer n.muNode.RUnlock()

	return n.pkgs.toList()
}

func (n *Node) Client() client.Client {
	n.muNode.RLock()
	defer n.muNode.RUnlock()

	return n.client
}

func (n *Node) GetRemoteAddress() string {
	return n.Node.Config().RPC.ListenAddress
}

// GetBlockTransactions returns the transactions contained
// within the specified block, if any
func (n *Node) GetBlockTransactions(blockNum uint64) ([]gnoland.TxWithMetadata, error) {
	n.muNode.RLock()
	defer n.muNode.RUnlock()

	return n.getBlockTransactions(blockNum)
}

// GetBlockTransactions returns the transactions contained
// within the specified block, if any
func (n *Node) getBlockTransactions(blockNum uint64) ([]gnoland.TxWithMetadata, error) {
	int64BlockNum := int64(blockNum)
	b, err := n.client.Block(&int64BlockNum)
	if err != nil {
		return []gnoland.TxWithMetadata{}, fmt.Errorf("unable to load block at height %d: %w", blockNum, err) // nothing to see here
	}

	txs := make([]gnoland.TxWithMetadata, len(b.Block.Data.Txs))
	for i, encodedTx := range b.Block.Data.Txs {
		// fallback on std tx
		var tx std.Tx
		if unmarshalErr := amino.Unmarshal(encodedTx, &tx); unmarshalErr != nil {
			return nil, fmt.Errorf("unable to unmarshal tx: %w", unmarshalErr)
		}

		txs[i] = gnoland.TxWithMetadata{
			Tx: tx,
			Metadata: &gnoland.GnoTxMetadata{
				Timestamp: b.BlockMeta.Header.Time.Unix(),
			},
		}
	}

	return txs, nil
}

// GetBlockTransactions returns the transactions contained
// within the specified block, if any
// GetLatestBlockNumber returns the latest block height from the chain
func (n *Node) GetLatestBlockNumber() (uint64, error) {
	n.muNode.RLock()
	defer n.muNode.RUnlock()

	return n.getLatestBlockNumber(), nil
}

func (n *Node) getLatestBlockNumber() uint64 {
	return uint64(n.Node.BlockStore().Height())
}

// UpdatePackages updates the currently known packages. It will be taken into
// consideration in the next reload of the node.
func (n *Node) UpdatePackages(paths ...string) error {
	n.muNode.Lock()
	defer n.muNode.Unlock()

	return n.updatePackages(paths...)
}

func (n *Node) updatePackages(paths ...string) error {
	var pkgsUpdated int
	for _, path := range paths {
		abspath, err := filepath.Abs(path)
		if err != nil {
			return fmt.Errorf("unable to resolve abs path of %q: %w", path, err)
		}

		// Check if we already know the path (or its parent) and set
		// associated deployer and deposit
		deployer := n.config.DefaultDeployer
		var deposit std.Coins
		for _, ppath := range n.config.PackagesPathList {
			if !strings.HasPrefix(abspath, ppath.Path) {
				continue
			}

			deployer = ppath.Creator
			deposit = ppath.Deposit
		}

		// List all packages from target path
		pkgslist, err := gnomod.ListPkgs(abspath)
		if err != nil {
			return fmt.Errorf("failed to list gno packages for %q: %w", path, err)
		}

		// Update or add package in the current known list.
		for _, pkg := range pkgslist {
			n.pkgs[pkg.Dir] = Package{
				Pkg:     pkg,
				Creator: deployer,
				Deposit: deposit,
			}

			n.logger.Debug("pkgs update", "name", pkg.Name, "path", pkg.Dir)
		}

		pkgsUpdated += len(pkgslist)
	}

	n.logger.Info(fmt.Sprintf("updated %d packages", pkgsUpdated))
	return nil
}

// Reset stops the node, if running, and reloads it with a new genesis state,
// effectively ignoring the current state.
func (n *Node) Reset(ctx context.Context) error {
	n.muNode.Lock()
	defer n.muNode.Unlock()

	// Stop the node if it's currently running.
	if err := n.stopIfRunning(); err != nil {
		return fmt.Errorf("unable to stop the node: %w", err)
	}

	// Reset starting time
	startTime := time.Now()

	// Generate a new genesis state based on the current packages
	pkgsTxs, err := n.pkgs.Load(DefaultFee, startTime)
	if err != nil {
		return fmt.Errorf("unable to load pkgs: %w", err)
	}

	// Append initialTxs
	txs := append(pkgsTxs, n.initialState...)
	genesis := gnoland.DefaultGenState()
	genesis.Balances = n.config.BalancesList
	genesis.Txs = txs

	// Reset the node with the new genesis state.
	err = n.rebuildNode(ctx, genesis)
	if err != nil {
		return fmt.Errorf("unable to initialize a new node: %w", err)
	}

	n.loadedPackages = len(pkgsTxs)
	n.currentStateIndex = len(n.initialState)
	n.startTime = startTime
	n.emitter.Emit(&events.Reset{})
	return nil
}

// ReloadAll updates all currently known packages and then reloads the node.
// It's actually a simple combination between `UpdatePackage` and `Reload` method.
func (n *Node) ReloadAll(ctx context.Context) error {
	n.muNode.Lock()
	defer n.muNode.Unlock()

	pkgs := n.pkgs.toList()
	paths := make([]string, len(pkgs))
	for i, pkg := range pkgs {
		paths[i] = pkg.Dir
	}

	if err := n.updatePackages(paths...); err != nil {
		return fmt.Errorf("unable to reload packages: %w", err)
	}

	return n.rebuildNodeFromState(ctx)
}

// Reload saves the current state, stops the node if running, starts a new node,
// and re-apply previously saved state along with packages updated by `UpdatePackages`.
// If any transaction, including 'addpkg', fails, it will be ignored.
// Use 'Reset' to completely reset the node's state in case of persistent errors.
func (n *Node) Reload(ctx context.Context) error {
	n.muNode.Lock()
	defer n.muNode.Unlock()

	return n.rebuildNodeFromState(ctx)
}

// SendTransaction executes a broadcast commit send
// of the specified transaction to the chain
func (n *Node) SendTransaction(tx *std.Tx) error {
	n.muNode.RLock()
	defer n.muNode.RUnlock()

	aminoTx, err := amino.Marshal(tx)
	if err != nil {
		return fmt.Errorf("unable to marshal transaction to amino binary, %w", err)
	}

	// we use BroadcastTxCommit to ensure to have one block with the given tx
	res, err := n.client.BroadcastTxCommit(aminoTx)
	if err != nil {
		return fmt.Errorf("unable to broadcast transaction commit: %w", err)
	}

	if res.CheckTx.Error != nil {
		n.logger.Error("check tx error trace", "log", res.CheckTx.Log)
		return fmt.Errorf("check transaction error: %w", res.CheckTx.Error)
	}

	if res.DeliverTx.Error != nil {
		n.logger.Error("deliver tx error trace", "log", res.CheckTx.Log)
		return fmt.Errorf("deliver transaction error: %w", res.DeliverTx.Error)
	}

	return nil
}

func (n *Node) getBlockStoreState(ctx context.Context) ([]gnoland.TxWithMetadata, error) {
	// get current genesis state
	genesis := n.GenesisDoc().AppState.(gnoland.GnoGenesisState)

	initialTxs := genesis.Txs[n.loadedPackages:] // ignore previously loaded packages
	state := append([]gnoland.TxWithMetadata{}, initialTxs...)

	lastBlock := n.getLatestBlockNumber()
	var blocnum uint64 = 1
	for ; blocnum <= lastBlock; blocnum++ {
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		default:
		}

		txs, txErr := n.getBlockTransactions(blocnum)
		if txErr != nil {
			return nil, fmt.Errorf("unable to fetch block transactions, %w", txErr)
		}

		state = append(state, txs...)
	}

	// override current state
	return state, nil
}

func (n *Node) stopIfRunning() error {
	if n.Node != nil && n.Node.IsRunning() {
		if err := n.Node.Stop(); err != nil {
			return fmt.Errorf("unable to stop the node: %w", err)
		}
	}

	return nil
}

func (n *Node) rebuildNodeFromState(ctx context.Context) error {
	if n.config.NoReplay {
		// If NoReplay is true, simply reset the node to its initial state
		n.logger.Warn("replay disabled")

		txs, err := n.pkgs.Load(DefaultFee, n.startTime)
		if err != nil {
			return fmt.Errorf("unable to load pkgs: %w", err)
		}
		genesis := gnoland.DefaultGenState()
		genesis.Balances = n.config.BalancesList
		genesis.Txs = txs
		return n.rebuildNode(ctx, genesis)
	}

	state, err := n.getBlockStoreState(ctx)
	if err != nil {
		return fmt.Errorf("unable to save state: %s", err.Error())
	}

	// Load genesis packages
	pkgsTxs, err := n.pkgs.Load(DefaultFee, n.startTime)
	if err != nil {
		return fmt.Errorf("unable to load pkgs: %w", err)
	}

	// Create genesis with loaded pkgs + previous state
	genesis := gnoland.DefaultGenState()
	genesis.Balances = n.config.BalancesList
	genesis.Txs = append(pkgsTxs, state...)

	// Reset the node with the new genesis state.
	err = n.rebuildNode(ctx, genesis)
	n.logger.Info("reload done", "pkgs", len(pkgsTxs), "state applied", len(state))

	// Update node infos
	n.loadedPackages = len(pkgsTxs)

	n.emitter.Emit(&events.Reload{})
	return nil
}

func (n *Node) handleEventTX(evt tm2events.Event) {
	switch data := evt.(type) {
	case bft.EventTx:
		go func() {
			// Use a separate goroutine in order to avoid a deadlock situation.
			// This is needed because this callback may get called during node rebuilding while
			// lock is held.
			n.muNode.Lock()
			defer n.muNode.Unlock()

			heigh := n.BlockStore().Height()
			n.currentStateIndex++
			n.state = nil // invalidate state

			n.logger.Info("node state", "index", n.currentStateIndex, "height", heigh)
		}()

		resEvt := events.TxResult{
			Height: data.Result.Height,
			Index:  data.Result.Index,
			// XXX: Update this to split error for stack
			Response: data.Result.Response,
		}

		if err := amino.Unmarshal(data.Result.Tx, &resEvt.Tx); err != nil {
			n.logger.Error("unable to unwrap tx result",
				"error", err)
		}

		n.emitter.Emit(resEvt)
	}
}

func (n *Node) rebuildNode(ctx context.Context, genesis gnoland.GnoGenesisState) (err error) {
	noopLogger := log.NewNoopLogger()

	// Stop the node if it's currently running.
	if err := n.stopIfRunning(); err != nil {
		return fmt.Errorf("unable to stop the node: %w", err)
	}

	// Setup node config
	nodeConfig := newNodeConfig(n.config.TMConfig, n.config.ChainID, n.config.ChainDomain, genesis)
	nodeConfig.GenesisTxResultHandler = n.genesisTxResultHandler
	// Speed up stdlib loading after first start (saves about 2-3 seconds on each reload).
	nodeConfig.CacheStdlibLoad = true
	nodeConfig.Genesis.ConsensusParams.Block.MaxGas = n.config.MaxGasPerBlock
	// Genesis verification is always false with Gnodev
	nodeConfig.SkipGenesisVerification = true

	// recoverFromError handles panics and converts them to errors.
	recoverFromError := func() {
		if r := recover(); r != nil {
			switch val := r.(type) {
			case error:
				err = val
			case string:
				err = fmt.Errorf("error: %s", val)
			default:
				err = fmt.Errorf("unknown error: %#v", val)
			}
		}
	}

	// Execute node creation and handle any errors.
	defer recoverFromError()

	// XXX: Redirect the node log somewhere else
	node, nodeErr := gnoland.NewInMemoryNode(noopLogger, nodeConfig)
	if nodeErr != nil {
		return fmt.Errorf("unable to create a new node: %w", err)
	}

	node.EventSwitch().AddListener("dev-emitter", n.handleEventTX)

	if startErr := node.Start(); startErr != nil {
		return fmt.Errorf("unable to start the node: %w", startErr)
	}

	// Wait for the node to be ready
	select {
	case <-node.Ready(): // Ok
		n.Node = node
	case <-ctx.Done():
		return ctx.Err()
	}

	return nil
}

func (n *Node) genesisTxResultHandler(ctx sdk.Context, tx std.Tx, res sdk.Result) {
	if !res.IsErr() {
		return
	}

	// XXX: for now, this is only way to catch the error
	before, after, found := strings.Cut(res.Log, "\n")
	if !found {
		n.logger.Error("unable to send tx", "err", res.Error, "log", res.Log)
		return
	}

	var attrs []slog.Attr

	// Add error
	attrs = append(attrs, slog.Any("err", res.Error))

	// Fetch first line as error message
	msg := strings.TrimFunc(before, func(r rune) bool {
		return unicode.IsSpace(r) || r == ':'
	})
	attrs = append(attrs, slog.String("err", msg))

	// If debug is enable, also append stack
	if n.logger.Enabled(context.Background(), slog.LevelDebug) {
		attrs = append(attrs, slog.String("stack", after))
	}

	n.logger.LogAttrs(context.Background(), slog.LevelError, "unable to deliver tx", attrs...)

	return
}

func newNodeConfig(tmc *tmcfg.Config, chainid, chaindomain string, appstate gnoland.GnoGenesisState) *gnoland.InMemoryNodeConfig {
	// Create Mocked Identity
	pv := gnoland.NewMockedPrivValidator()
	genesis := gnoland.NewDefaultGenesisConfig(chainid, chaindomain)
	genesis.AppState = appstate

	// Add self as validator
	self := pv.GetPubKey()
	genesis.Validators = []bft.GenesisValidator{
		{
			Address: self.Address(),
			PubKey:  self,
			Power:   10,
			Name:    "self",
		},
	}

	cfg := &gnoland.InMemoryNodeConfig{
		PrivValidator: pv,
		TMConfig:      tmc,
		Genesis:       genesis,
		VMOutput:      os.Stdout,
	}
	return cfg
}
