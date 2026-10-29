package integration

import (
	"os"
	"path/filepath"
	"testing"

	gno_integration "github.com/gnolang/gno/gnovm/pkg/integration"
	"github.com/gnolang/gno/gno.land/pkg/integration"
	"github.com/rogpeppe/go-internal/testscript"
)

// TestTxtar runs testdata/*.txtar against an in-memory gno.land node.
// The repo's src is copied to $WORK/src so scripts can loadpkg and addpkg it.
func TestTxtar(t *testing.T) {
	src, err := filepath.Abs("../src")
	if err != nil {
		t.Fatal(err)
	}
	p := gno_integration.NewTestingParams(t, "testdata")
	if err := integration.SetupGnolandTestscript(t, &p); err != nil {
		t.Fatal(err)
	}
	setup := p.Setup
	p.Setup = func(env *testscript.Env) error {
		if err := os.CopyFS(filepath.Join(env.WorkDir, "src"), os.DirFS(src)); err != nil {
			return err
		}
		return setup(env)
	}
	testscript.Run(t, p)
}
