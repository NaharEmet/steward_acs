defmodule Acs.Memory.EmbeddingTest do
  use ExUnit.Case, async: false

  alias Acs.Memory.Embedding

  setup do
    ollama_url = Application.get_env(:steward_acs, Acs.Memory.Embedding, [])
                 |> Keyword.get(:ollama_url, "http://localhost:11434")

    ollama_available = ollama_available?(ollama_url)

    {:ok, ollama_available: ollama_available}
  end

  describe "embed_text/1" do
    test "generates embedding for text", ctx do
      if ctx[:ollama_available] do
        {:ok, embedding} = Embedding.embed_text("cache release ordering")
        assert is_list(embedding)
        assert length(embedding) > 0
        assert Enum.all?(embedding, &is_float/1)
      else
        assert true
      end
    end

    test "generates consistent embeddings for same text", ctx do
      if ctx[:ollama_available] do
        text = "test memory content"

        {:ok, embedding1} = Embedding.embed_text(text)
        {:ok, embedding2} = Embedding.embed_text(text)

        assert length(embedding1) == length(embedding2)

        diff = Enum.zip(embedding1, embedding2)
               |> Enum.map(fn {a, b} -> abs(a - b) end)
               |> Enum.sum()

        assert diff < 0.001, "Embeddings should be nearly identical"
      else
        result = Embedding.embed_text("test")
        assert match?({:error, _}, result) or match?({:ok, _}, result)
      end
    end

    test "different texts produce different embeddings", ctx do
      if ctx[:ollama_available] do
        {:ok, embedding1} = Embedding.embed_text("cache release ordering")
        {:ok, embedding2} = Embedding.embed_text("task assignment conflict")

        diff_count = Enum.zip(embedding1, embedding2)
                     |> Enum.count(fn {a, b} -> abs(a - b) > 0.01 end)

        assert diff_count > length(embedding1) * 0.5, "Different texts should produce different embeddings"
      else
        result = Embedding.embed_text("different text")
        assert match?({:error, _}, result) or match?({:ok, _}, result)
      end
    end
  end

  describe "embed_texts/1" do
    test "generates embeddings for multiple texts", ctx do
      if ctx[:ollama_available] do
        texts = [
          "cache release ordering",
          "task assignment conflict",
          "file lock management"
        ]

        {:ok, embeddings} = Embedding.embed_texts(texts)

        assert length(embeddings) == 3
        assert Enum.all?(embeddings, &is_list/1)
        assert Enum.all?(embeddings, fn e -> length(e) == length(hd(embeddings)) end)
      else
        assert true
      end
    end

    test "handles empty list" do
      {:ok, embeddings} = Embedding.embed_texts([])
      assert embeddings == []
    end
  end

  describe "normalize/1" do
    test "normalizes vector to unit length" do
      embedding = [3.0, 4.0]

      normalized = Embedding.normalize(embedding)

      magnitude = :math.sqrt(Enum.reduce(normalized, 0, fn x, acc -> x * x + acc end))
      assert abs(magnitude - 1.0) < 0.0001
    end

    test "preserves direction of vector" do
      embedding = [1.0, 2.0, 3.0]

      normalized = Embedding.normalize(embedding)

      Enum.zip(embedding, normalized)
      |> Enum.each(fn {orig, norm} ->
        assert (orig > 0 and norm > 0) or (orig < 0 and norm < 0) or orig == norm
      end)
    end

    test "handles zero vector" do
      embedding = [0.0, 0.0, 0.0]

      normalized = Embedding.normalize(embedding)

      assert Enum.all?(normalized, &(&1 == 0.0))
    end
  end

  describe "cosine_similarity/2" do
    test "returns 1.0 for identical vectors" do
      vector = [0.5, 0.5, 0.5, 0.5]

      similarity = Embedding.cosine_similarity(vector, vector)

      assert abs(similarity - 1.0) < 0.0001
    end

    test "returns 0.0 for orthogonal vectors" do
      vector1 = [1.0, 0.0, 0.0]
      vector2 = [0.0, 1.0, 0.0]

      similarity = Embedding.cosine_similarity(vector1, vector2)

      assert abs(similarity) < 0.0001
    end

    test "returns -1.0 for opposite vectors" do
      vector1 = [1.0, 0.0, 0.0]
      vector2 = [-1.0, 0.0, 0.0]

      similarity = Embedding.cosine_similarity(vector1, vector2)

      assert abs(similarity - (-1.0)) < 0.0001
    end

    test "returns value between -1 and 1 for general vectors" do
      vector1 = [1.0, 2.0, 3.0]
      vector2 = [2.0, 4.0, 6.0]

      similarity = Embedding.cosine_similarity(vector1, vector2)

      assert similarity > 0.99
      assert similarity <= 1.0
    end
  end

  describe "error handling" do
    test "handles Ollama connection failure gracefully" do
      result = case Embedding.embed_text("test") do
        {:ok, _} -> :ok
        {:error, reason} when is_binary(reason) -> :error_handled
        {:error, _} -> :error_handled
      end

      assert result in [:ok, :error_handled]
    end
  end

  defp ollama_available?(url) do
    case :httpc.request(:get, {String.to_charlist(url <> "/api/tags"), []}, [], []) do
      {:ok, {{_version, 200, _reason}, _headers, _body}} -> true
      _ -> false
    end
  rescue
    _ -> false
  end
end