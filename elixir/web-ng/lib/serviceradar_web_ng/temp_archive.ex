defmodule ServiceRadarWebNG.TempArchive do
  @moduledoc false

  Module.register_attribute(__MODULE__, :sobelow_skip, accumulate: true)

  @retry_attempts 5

  @spec create_tar_gz(String.t(), [{String.t(), iodata() | nil}]) ::
          {:ok, binary()} | {:error, term()}
  @sobelow_skip ["Traversal.FileModule"]
  def create_tar_gz(prefix, files) when is_binary(prefix) and is_list(files) do
    with_secure_temp_path(prefix, fn tmp_path ->
      {:ok, tar} = :erl_tar.open(String.to_charlist(tmp_path), [:write, :compressed])

      try do
        files
        |> Enum.with_index()
        |> Enum.each(fn {{name, content}, index} ->
          # :erl_tar gives an in-memory entry mode 0644; only a file on disk carries its own.
          entry_path = Path.join(Path.dirname(tmp_path), "entry-#{index}")
          File.write!(entry_path, content || "")
          File.chmod!(entry_path, file_mode(name))

          :ok =
            :erl_tar.add(tar, String.to_charlist(entry_path), String.to_charlist(name), [{:uid, 0}, {:gid, 0}])
        end)
      after
        :erl_tar.close(tar)
      end

      File.read(tmp_path)
    end)
  rescue
    error -> {:error, {:tar_creation_failed, error}}
  end

  defp file_mode(name) do
    cond do
      String.ends_with?(name, ".sh") -> 0o755
      String.ends_with?(name, ["-key.pem", ".creds"]) -> 0o600
      true -> 0o644
    end
  end

  @sobelow_skip ["Traversal.FileModule"]
  defp with_secure_temp_path(prefix, fun) when is_function(fun, 1) do
    base_dir = Path.join(System.tmp_dir!(), "serviceradar")
    File.mkdir_p!(base_dir)
    do_with_secure_temp_path(base_dir, prefix, fun, @retry_attempts)
  end

  defp do_with_secure_temp_path(_base_dir, _prefix, _fun, 0) do
    {:error, :tempfile_allocation_failed}
  end

  @sobelow_skip ["Traversal.FileModule"]
  defp do_with_secure_temp_path(base_dir, prefix, fun, attempts_left) do
    random =
      16
      |> :crypto.strong_rand_bytes()
      |> Base.url_encode64(padding: false)

    temp_dir = Path.join(base_dir, "#{prefix}-#{random}")

    case File.mkdir(temp_dir) do
      :ok ->
        tmp_path = Path.join(temp_dir, "archive.tar.gz")
        File.chmod!(temp_dir, 0o700)

        try do
          fun.(tmp_path)
        after
          _ = File.rm_rf(temp_dir)
        end

      {:error, :eexist} ->
        do_with_secure_temp_path(base_dir, prefix, fun, attempts_left - 1)

      {:error, reason} ->
        {:error, reason}
    end
  end
end
