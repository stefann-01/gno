package client

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"os"

	"github.com/gnolang/gno/tm2/pkg/commands"
	"github.com/gnolang/gno/tm2/pkg/crypto"
	"github.com/gnolang/gno/tm2/pkg/crypto/keys"
	"github.com/gnolang/gno/tm2/pkg/crypto/keys/armor"
)

type ImportCfg struct {
	RootCfg *BaseCfg

	KeyName   string
	ArmorPath string
	Unsafe    bool
}

func NewImportCmd(rootCfg *BaseCfg, io commands.IO) *commands.Command {
	cfg := &ImportCfg{
		RootCfg: rootCfg,
	}

	return commands.NewCommand(
		commands.Metadata{
			Name:       "import",
			ShortUsage: "import [flags]",
			ShortHelp:  "imports encrypted private key armor",
		},
		cfg,
		func(_ context.Context, _ []string) error {
			return execImport(cfg, io)
		},
	)
}

func (c *ImportCfg) RegisterFlags(fs *flag.FlagSet) {
	fs.StringVar(
		&c.KeyName,
		"name",
		"",
		"name of the private key",
	)

	fs.StringVar(
		&c.ArmorPath,
		"armor-path",
		"",
		"path to the encrypted armor file",
	)

	fs.BoolVar(
		&c.Unsafe,
		"unsafe",
		false,
		"import the private key armor as unencrypted",
	)
}

func execImport(cfg *ImportCfg, io commands.IO) error {
	// check keyname
	if cfg.KeyName == "" {
		return errors.New("name shouldn't be empty")
	}

	// Create a new instance of the key-base
	kb, err := keys.NewKeyBaseFromDir(cfg.RootCfg.Home)
	if err != nil {
		return fmt.Errorf(
			"unable to create a key base from directory %s, %w",
			cfg.RootCfg.Home,
			err,
		)
	}

	// Read the raw encrypted armor
	keyArmor, err := os.ReadFile(cfg.ArmorPath)
	if err != nil {
		return fmt.Errorf(
			"unable to read armor from path %s, %w",
			cfg.ArmorPath,
			err,
		)
	}

	var (
		decryptPassword string
		encryptPassword string
	)

	if !cfg.Unsafe {
		// Get the armor decrypt password
		decryptPassword, err = io.GetPassword(
			"Enter the passphrase to decrypt your private key armor:",
			cfg.RootCfg.InsecurePasswordStdin,
		)
		if err != nil {
			return fmt.Errorf(
				"unable to retrieve armor decrypt password from user, %w",
				err,
			)
		}
	}

	// Get the key-base encrypt password
	encryptPassword, err = io.GetCheckPassword(
		[2]string{
			"Enter a passphrase to encrypt your private key:",
			"Repeat the passphrase:",
		},
		cfg.RootCfg.InsecurePasswordStdin,
	)
	if err != nil {
		return fmt.Errorf(
			"unable to retrieve key encrypt password from user, %w",
			err,
		)
	}

	var privateKey crypto.PrivKey

	if cfg.Unsafe {
		// Un-armor the private key
		privateKey, err = armor.UnarmorPrivateKey(string(keyArmor))
		if err != nil {
			return fmt.Errorf("unable to unarmor private key, %w", err)
		}
	} else {
		// Decrypt the armor
		privateKey, err = armor.UnarmorDecryptPrivKey(string(keyArmor), decryptPassword)
		if err != nil {
			return fmt.Errorf("unable to decrypt private key armor, %w", err)
		}
	}

	// Import the private key
	if err := kb.ImportPrivKey(
		cfg.KeyName,
		privateKey,
		encryptPassword,
	); err != nil {
		return fmt.Errorf(
			"unable to import the encrypted private key, %w",
			err,
		)
	}

	io.Printfln("Successfully imported private key %s", cfg.KeyName)

	return nil
}
