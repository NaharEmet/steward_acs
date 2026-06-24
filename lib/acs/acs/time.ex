defmodule Acs.Acs.Time do
  @moduledoc """
  Time utilities for ACS with adjustable time offset.

  Provides time synchronization capabilities through a configurable offset
  that adjusts all timestamps used in ACS operations.
  """

  alias Acs.Acs.Cache

  @time_offset_file "priv/acs_time_offset.txt"

  @doc """
  Returns the current time adjusted by the configured time offset.

  If no offset is set, returns DateTime.utc_now().
  """
  def adjusted_now do
    offset = Cache.get_time_offset()
    DateTime.utc_now() |> DateTime.add(offset, :second)
  end

  @doc """
  Returns the current time offset in seconds.
  """
  def get_time_offset do
    Cache.get_time_offset()
  end

  @doc """
  Sets the time offset in seconds and persists it.
  """
  def set_time_offset(seconds) when is_integer(seconds) do
    Cache.set_time_offset(seconds)
    persist_time_offset(seconds)
    :ok
  end

  @doc """
  Returns the system time (DateTime.utc_now() without offset).
  """
  def system_time do
    DateTime.utc_now()
  end

  @doc """
  Syncs the time offset by comparing system time with a reference.
  If sync_offset is provided (in seconds), sets the offset directly.
  """
  def sync_time(sync_offset \\ nil) when is_integer(sync_offset) or is_nil(sync_offset) do
    if is_nil(sync_offset) do
      # Auto-sync not implemented - just ensure offset is loaded
      Cache.get_time_offset()
    else
      set_time_offset(sync_offset)
    end
  end

  # File-based persistence
  defp persist_time_offset(seconds) do
    Path.dirname(@time_offset_file) |> File.mkdir_p!()
    File.write(@time_offset_file, Integer.to_string(seconds))
  end
end