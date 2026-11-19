package mobile

import (
	"crypto/rand"
	"encoding/json"
	"errors"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"sync"

	"github.com/metacubex/mihomo/component/fakeip"
)

const fakeIPStateLimit = 2 * 1024 * 1024
const fakeIPStateFile = "fake-ip.json"

type fakeIPState struct {
	mu     sync.Mutex
	root   *os.Root
	pools  [2]*fakeip.Pool
	saved  [2]uint64
	report func(string)
}

type fakeIPSnapshot struct {
	Version int                    `json:"version"`
	Pools   [2]*fakeip.MemoryState `json:"pools"`
}

func openFakeIPState(directory string, enabled bool, pools [2]*fakeip.Pool, report func(string)) (*fakeIPState, error) {
	if directory == "" {
		if enabled {
			return nil, errors.New("profile.store-fake-ip requires a controlled profile state directory")
		}
		return nil, nil
	}
	info, err := os.Lstat(directory)
	if err != nil || !filepath.IsAbs(directory) || !info.IsDir() {
		return nil, errors.New("Fake-IP state root must be an absolute directory without symlinks")
	}
	root, err := os.OpenRoot(directory)
	if err != nil {
		return nil, errors.New("Fake-IP state directory is unavailable")
	}
	state := &fakeIPState{root: root, pools: pools, report: report}
	if !enabled {
		err := root.Remove(fakeIPStateFile)
		_ = root.Close()
		if err != nil && !errors.Is(err, fs.ErrNotExist) {
			return nil, errors.New("cannot clear disabled Fake-IP state")
		}
		return nil, nil
	}
	if err := state.restore(); err != nil {
		_ = root.Close()
		return nil, err
	}
	for index, pool := range pools {
		if pool != nil {
			state.saved[index] = pool.MemoryRevision()
		}
	}
	return state, nil
}

func (s *fakeIPState) restore() error {
	info, err := s.root.Lstat(fakeIPStateFile)
	if errors.Is(err, fs.ErrNotExist) {
		return nil
	}
	if err != nil || !info.Mode().IsRegular() || info.Size() > fakeIPStateLimit {
		return errors.New("Fake-IP state must be a regular file within the size limit")
	}
	file, err := s.root.Open(fakeIPStateFile)
	if err != nil {
		return errors.New("cannot read Fake-IP state")
	}
	defer file.Close()
	data, err := io.ReadAll(io.LimitReader(file, fakeIPStateLimit+1))
	if err != nil || len(data) > fakeIPStateLimit {
		return errors.New("cannot read bounded Fake-IP state")
	}
	var snapshot fakeIPSnapshot
	if json.Unmarshal(data, &snapshot) != nil || snapshot.Version != 1 {
		return errors.New("saved Fake-IP state is invalid")
	}
	for index, pool := range s.pools {
		if pool == nil || snapshot.Pools[index] == nil {
			continue
		}
		if err := pool.ImportMemoryState(*snapshot.Pools[index]); err != nil {
			return err
		}
	}
	return nil
}

func (s *fakeIPState) save() error {
	if s == nil {
		return nil
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	changed := false
	for index, pool := range s.pools {
		if pool != nil && pool.MemoryRevision() != s.saved[index] {
			changed = true
		}
	}
	if !changed {
		return nil
	}
	snapshot := fakeIPSnapshot{Version: 1}
	var revisions [2]uint64
	for index, pool := range s.pools {
		if pool == nil {
			continue
		}
		state, revision, err := pool.ExportMemoryState()
		if err != nil {
			return err
		}
		snapshot.Pools[index], revisions[index] = &state, revision
	}
	data, err := json.Marshal(snapshot)
	if err != nil || len(data) > fakeIPStateLimit {
		return errors.New("Fake-IP state exceeds the size limit")
	}
	if err := s.write(data); err != nil {
		if s.report != nil {
			s.report("Fake-IP state could not be saved")
		}
		return errors.New("Fake-IP state could not be saved")
	}
	s.saved = revisions
	return nil
}

func (s *fakeIPState) write(data []byte) error {
	name := ".fake-ip-" + rand.Text()
	file, err := s.root.OpenFile(name, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err != nil {
		return err
	}
	defer s.root.Remove(name)
	_, err = file.Write(data)
	if err == nil {
		err = file.Sync()
	}
	err = errors.Join(err, file.Close())
	if err != nil {
		return err
	}
	return s.root.Rename(name, fakeIPStateFile)
}

func (s *fakeIPState) Close() error {
	return errors.Join(s.save(), s.root.Close())
}
