defmodule BotArmyTerrain.Skills.PopulateGraph do
  @moduledoc """
  Skill for extracting concepts from topics and populating the knowledge graph.

  Processes:
  - Topic name and content/description
  - Uses LLM to extract key concepts and relationships
  - Stores concepts as nodes, relationships as edges in knowledge graph
  - Example: "Systems Design" → concepts: scalability, databases, caching, etc.

  Enables semantic discovery:
  - "What are the prerequisites for topic X?"
  - "What concepts are part of this learning path?"
  - "How are these topics related?"

  Trigger: bot.army.terrain.command.populate_graph
  """

  use BotArmy.Skill
  require Logger

  @impl true
  def name, do: :populate_graph

  @impl true
  def description do
    "Extract concepts from topics and populate knowledge graph"
  end

  @impl true
  def nats_triggers do
    [
      "bot.army.terrain.command.populate_graph"
    ]
  end

  @impl true
  def llm_hint, do: :quality

  @impl true
  def validate(input) when is_map(input) do
    has_topic_id = is_binary(input["topic_id"]) and byte_size(input["topic_id"]) > 0
    has_content = is_binary(input["content"]) and byte_size(input["content"]) > 0
    has_name = is_binary(input["topic_name"]) and byte_size(input["topic_name"]) > 0

    if has_topic_id and (has_content or has_name) do
      :ok
    else
      {:error, "topic_id and (content or topic_name) fields required"}
    end
  end

  def validate(_) do
    {:error, "input must be a map"}
  end

  @impl true
  def execute(input, ctx) do
    try do
      topic_id = input["topic_id"]
      topic_name = input["topic_name"]
      content = input["content"]

      # Use LLM to extract concepts and relationships
      with {:ok, extraction} <- extract_concepts(content || topic_name, ctx.llm) do
        # Populate knowledge graph
        case populate_graph(topic_id, topic_name, extraction) do
          {:ok, graph_data} ->
            Logger.info("[PopulateGraph] Graph populated for topic #{topic_id}")
            {:ok, graph_data}

          {:error, reason} ->
            Logger.error("[PopulateGraph] Failed to populate graph: #{inspect(reason)}")
            {:error, {:graph_population_failed, reason}}
        end
      end
    rescue
      e ->
        Logger.error("[PopulateGraph] Execution failed", error: inspect(e))
        {:error, :execution_failed}
    end
  end

  # Private helpers

  defp extract_concepts(content, llm_module) do
    prompt = extraction_prompt(content)

    with {:ok, raw_response} <- llm_module.request(prompt, hint: :quality) do
      case Jason.decode(raw_response) do
        {:ok, extraction} -> {:ok, extraction}
        {:error, _} -> parse_extraction_fallback(raw_response)
      end
    end
  end

  defp extraction_prompt(content) do
    """
    Extract the key concepts and relationships from the following topic/content.

    Return a JSON object with:
    - "concepts": array of concept strings (e.g., ["scalability", "databases", "caching"])
    - "prerequisites": array of concepts that are prerequisites (e.g., ["databases"])
    - "related_concepts": array of objects with {from, to, relationship} (e.g., [{from: "databases", to: "scalability", relationship: "enables"}])
    - "summary": one sentence summary of what this topic is about

    Topic/Content:
    #{content}

    Respond with valid JSON only.
    """
  end

  defp parse_extraction_fallback(raw_response) do
    # Try to extract JSON from markdown code blocks or raw text
    case extract_json_from_text(raw_response) do
      {:ok, json} -> {:ok, json}
      :error -> {:error, :json_parse_failed}
    end
  end

  defp extract_json_from_text(text) do
    # Try to find JSON in code blocks first
    case Regex.run(~r/```(?:json)?\s*(\{[\s\S]*?\})\s*```/, text, capture: :all_but_first) do
      [json_str] -> Jason.decode(json_str)
      _ -> Jason.decode(text)
    end
  end

  defp populate_graph(topic_id, topic_name, extraction) do
    concepts = extraction["concepts"] || []
    prerequisites = extraction["prerequisites"] || []
    related_concepts = extraction["related_concepts"] || []

    try do
      # Create topic node
      topic_node = %{
        id: topic_id,
        type: "topic",
        name: topic_name,
        properties: %{
          summary: extraction["summary"],
          concept_count: length(concepts)
        }
      }

      # Create concept nodes
      concept_nodes =
        Enum.map(concepts, fn concept ->
          %{
            id: String.downcase(concept),
            type: "concept",
            name: concept,
            properties: %{
              is_prerequisite: concept in prerequisites
            }
          }
        end)

      # Create edges: topic -> concept relationships
      topic_to_concept_edges =
        Enum.map(concepts, fn concept ->
          edge_type =
            if concept in prerequisites do
              "REQUIRES"
            else
              "INCLUDES"
            end

          %{
            from_id: topic_id,
            to_id: String.downcase(concept),
            type: edge_type,
            properties: %{}
          }
        end)

      # Create edges: concept -> concept relationships
      concept_to_concept_edges =
        Enum.map(related_concepts, fn rel ->
          %{
            from_id: String.downcase(rel["from"]),
            to_id: String.downcase(rel["to"]),
            type: rel["relationship"] || "RELATED_TO",
            properties: %{}
          }
        end)

      all_nodes = [topic_node] ++ concept_nodes
      all_edges = topic_to_concept_edges ++ concept_to_concept_edges

      # Upsert to knowledge graph
      with {:ok, _} <- BotArmy.Graph.upsert_nodes(all_nodes),
           {:ok, _} <- BotArmy.Graph.upsert_edges(all_edges) do
        {:ok, %{
          topic_id: topic_id,
          concepts_added: length(concept_nodes),
          relationships_added: length(all_edges),
          prerequisites: prerequisites,
          summary: extraction["summary"]
        }}
      end
    rescue
      e ->
        Logger.error("[PopulateGraph] Graph upsert failed", error: inspect(e))
        {:error, :graph_upsert_failed}
    end
  end
end
