defmodule ServiceRadarWebNG.Plugins.FirstPartyVersionSync do
  @moduledoc """
  One-shot boot task that syncs the first-party plugin index immediately when
  `SERVICERADAR_RELEASE_VERSION` changed, instead of waiting for the hourly tick.

  It lives in the Plugins boundary so the application supervisor can start it by
  name without calling into Plugins, which depends on `ServiceRadarWebNG`.
  """

  use Task, restart: :temporary

  alias ServiceRadarWebNG.Plugins.FirstPartySyncWorker

  def start_link(_arg), do: Task.start_link(&FirstPartySyncWorker.enqueue_if_version_changed/0)
end
