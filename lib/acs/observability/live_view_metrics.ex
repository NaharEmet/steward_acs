defmodule Acs.Observability.LiveViewMetrics do
  @moduledoc "Exports LiveView mount latency as bounded structured events."

  alias Acs.Observability.Events

  @handler_id {__MODULE__, :mount}

  def attach do
    :telemetry.detach(@handler_id)

    :telemetry.attach_many(
      @handler_id,
      [
        [:phoenix, :live_view, :mount, :stop],
        [:phoenix, :live_view, :mount, :exception]
      ],
      &__MODULE__.handle_event/4,
      nil
    )

    :ok
  end

  def handle_event([:phoenix, :live_view, :mount, :stop], measurements, metadata, _) do
    Events.info("LiveView mounted",
      component: "live_view",
      action: "mount",
      status: "ok",
      live_view: view_name(metadata),
      page: page(metadata),
      latency_ms: duration_ms(measurements)
    )
  end

  def handle_event([:phoenix, :live_view, :mount, :exception], measurements, metadata, _) do
    Events.warning("LiveView mount failed",
      component: "live_view",
      action: "mount",
      status: "error",
      error_type: metadata[:kind],
      live_view: view_name(metadata),
      page: page(metadata),
      latency_ms: duration_ms(measurements)
    )
  end

  defp duration_ms(%{duration: duration}),
    do: System.convert_time_unit(duration, :native, :microsecond) / 1_000

  defp duration_ms(_), do: nil

  defp view_name(%{socket: %{view: view}}) when is_atom(view), do: inspect(view)
  defp view_name(_), do: nil

  defp page(%{uri: uri}) when is_binary(uri), do: uri |> URI.parse() |> Map.get(:path)
  defp page(_), do: nil
end
