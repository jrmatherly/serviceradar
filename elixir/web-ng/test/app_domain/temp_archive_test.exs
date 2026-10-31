defmodule ServiceRadarWebNG.TempArchiveTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNG.TempArchive

  @moduletag :db_free

  test "creates a gzipped tarball from in-memory files" do
    assert {:ok, tarball} =
             TempArchive.create_tar_gz("serviceradar-test", [
               {"bundle/file.txt", "hello"},
               {"bundle/other.txt", "world"}
             ])

    assert is_binary(tarball)
    assert byte_size(tarball) > 0

    assert {:ok, files} = :erl_tar.extract({:binary, tarball}, [:compressed, :memory])

    contents =
      Map.new(files, fn {path, content} ->
        {List.to_string(path), IO.iodata_to_binary(content)}
      end)

    assert contents["bundle/file.txt"] == "hello"
    assert contents["bundle/other.txt"] == "world"
  end

  test "an extracted script runs and an extracted secret is private to its owner" do
    assert {:ok, tarball} =
             TempArchive.create_tar_gz("serviceradar-test", [
               {"bundle/update.sh", "#!/bin/bash\n"},
               {"bundle/creds/nats.creds", "creds"},
               {"bundle/certs/collector-key.pem", "key"},
               {"bundle/certs/collector.pem", "cert"},
               {"bundle/empty.txt", nil}
             ])

    assert {:ok, table} = :erl_tar.table({:binary, tarball}, [:compressed, :verbose])

    entries =
      Map.new(table, fn {name, :regular, _size, _mtime, mode, uid, gid} ->
        {List.to_string(name), {Bitwise.band(mode, 0o7777), uid, gid}}
      end)

    assert entries == %{
             "bundle/update.sh" => {0o755, 0, 0},
             "bundle/creds/nats.creds" => {0o600, 0, 0},
             "bundle/certs/collector-key.pem" => {0o600, 0, 0},
             "bundle/certs/collector.pem" => {0o644, 0, 0},
             "bundle/empty.txt" => {0o644, 0, 0}
           }
  end
end
