defmodule AcsWeb.PubSub do
  def subscribe(pubsub, topic, opts \\ []) do
    Phoenix.PubSub.subscribe(pubsub, topic, opts)
  end

  def broadcast(pubsub, topic, message) do
    Phoenix.PubSub.broadcast(pubsub, topic, message)
  end

  def broadcast!(pubsub, topic, message) do
    Phoenix.PubSub.broadcast!(pubsub, topic, message)
  end

  def direct_broadcast(pubsub, node, topic, message) do
    Phoenix.PubSub.direct_broadcast(pubsub, node, topic, message)
  end

  def direct_broadcast!(pubsub, node, topic, message) do
    Phoenix.PubSub.direct_broadcast!(pubsub, node, topic, message)
  end
end
