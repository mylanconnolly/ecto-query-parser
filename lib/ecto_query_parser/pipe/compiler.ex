defmodule EctoQueryParser.Pipe.Compiler do
  @moduledoc false

  # Folds a parsed pipe query (EctoQueryParser.Pipe.Query) onto an Ecto
  # query, stage by stage.
  #
  # ## Compilation contexts
  #
  # The compiler tracks one of two contexts while folding:
  #
  #   * `:base` — the query still exposes the source's own columns. Filters
  #     run through the full existing machinery (params, EXISTS rewriting for
  #     plural associations, allowlist checks, joins); select/group/sort
  #     columns resolve through the same identifier rules (association paths,
  #     JSONB paths).
  #
  #   * `:derived` — a `select` or `group` stage has projected the query into
  #     a fixed set of named output columns. Later stages address those
  #     columns only.
  #
  # ## Subquery wrapping
  #
  # A projection stage leaves the context with `pending_wrap: true`. The next
  # stage that references columns (filter/select/group/sort) first wraps the
  # accumulated query in a subquery — so `filter` after `group` becomes a
  # WHERE over the grouped output (HAVING semantics), and `sort -total` after
  # `group` orders by the aggregation alias. Stages that don't reference
  # columns (`limit`/`offset`) apply to the current level directly, but flag
  # the level so a later column-referencing stage still wraps (staged
  # semantics: `limit 10 | sort x` sorts the 10 rows). Consecutive filters at
  # the same level merge into one query level (multiple WHERE clauses).
  #
  # In the `:base` context there is no projection to wrap (a schemaless
  # source has no select), so column-referencing stages after `limit`/
  # `offset` are rejected with a clear error.
  #
  # ## Atom safety (output column names)
  #
  # Ecto subqueries and map selects require atom column keys, but aliases
  # come from untrusted input. Aliases therefore NEVER become atoms: every
  # projection selects into positional keys `:c0..:c63` (a fixed,
  # compile-time set capped at 64 columns), and the compiler tracks the
  # user-facing name for each key. `build_pipe` returns that mapping so
  # callers can rename result rows.

  import Ecto.Query

  alias EctoQueryParser.{Builder, ExistsRewriter, Identifier, Joins, Params, ValidationError}
  alias EctoQueryParser.Pipe.Query, as: PipeQuery

  @max_columns 64
  # Fixed, compile-time key set: hostile alias floods can never mint atoms.
  @column_keys Enum.map(0..(@max_columns - 1), &:"c#{&1}")

  @source_binding :__eqp_source

  @round_functions ~w(round_second round_minute round_hour round_day
                      round_week round_month round_quarter round_year)

  @doc """
  Compiles a parsed pipe query into `{:ok, query, columns}` or
  `{:error, reason}`.
  """
  def compile(%PipeQuery{source: source, stages: stages}, opts) do
    with :ok <- check_single_use(stages, :limit),
         :ok <- check_single_use(stages, :offset),
         {:ok, ctx} <- init_source(source, opts) do
      stages
      |> Enum.with_index(1)
      |> Enum.reduce_while({:ok, ctx}, fn {stage, index}, {:ok, ctx} ->
        case apply_stage(stage, index, ctx) do
          {:ok, ctx} -> {:cont, {:ok, ctx}}
          {:error, _} = error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, %{mode: :derived} = ctx} ->
          {:ok, ctx.query, Enum.map(ctx.cols, &%{name: &1.name, key: &1.key})}

        {:ok, ctx} ->
          {:ok, ctx.query, nil}

        {:error, _} = error ->
          error
      end
    end
  end

  # --- Sources ---

  defp init_source({:table, name, _pos}, opts) do
    {prefix, table} =
      case String.split(name, ".") do
        [table] -> {nil, table}
        [prefix, table] -> {prefix, table}
      end

    query = Ecto.Queryable.to_query(table)
    query = if prefix, do: %{query | from: %{query.from | prefix: prefix}}, else: query

    {:ok, base_ctx(name_source_binding(query), Keyword.get(opts, :allowed_fields), opts)}
  end

  defp init_source({:ref, slug, pos}, opts) do
    case Keyword.get(opts, :resolve_source) do
      nil ->
        validation_error(
          "source",
          nil,
          pos,
          "cannot resolve @#{slug}: no :resolve_source option was provided"
        )

      resolver when is_function(resolver, 1) ->
        resolve_ref(resolver, slug, pos, opts)

      other ->
        {:error, "resolve_source must be a 1-arity function, got: #{inspect(other)}"}
    end
  end

  defp resolve_ref(resolver, slug, pos, opts) do
    case resolver.(slug) do
      {:ok, queryable, fields} when is_list(fields) ->
        inner = Ecto.Queryable.to_query(queryable)
        query = name_source_binding(from(s in subquery(inner)))
        {:ok, base_ctx(query, fields, opts)}

      {:error, message} ->
        validation_error(
          "source",
          nil,
          pos,
          "cannot resolve @#{slug}: #{format_message(message)}"
        )

      other ->
        validation_error(
          "source",
          nil,
          pos,
          "resolve_source must return {:ok, queryable, fields} or {:error, message}, " <>
            "got: #{inspect(other)}"
        )
    end
  end

  defp format_message(message) when is_binary(message), do: message
  defp format_message(message), do: inspect(message)

  defp base_ctx(query, allowed, opts) do
    %{
      mode: :base,
      query: query,
      allowed: allowed,
      cols: nil,
      pending_wrap: false,
      limited: false,
      opts: opts
    }
  end

  # Names the source binding so EXISTS subqueries in base-context filters can
  # correlate via parent_as. Mirrors EctoQueryParser.apply/3.
  defp name_source_binding(%Ecto.Query{from: %{as: nil} = from, aliases: aliases} = query) do
    %{query | from: %{from | as: @source_binding}, aliases: Map.put(aliases, @source_binding, 0)}
  end

  defp name_source_binding(%Ecto.Query{} = query), do: query

  # --- limit/offset multiplicity ---

  defp check_single_use(stages, kind) do
    stages
    |> Enum.with_index(1)
    |> Enum.filter(fn {stage, _index} -> elem(stage, 0) == kind end)
    |> case do
      [_, {{^kind, _n, pos}, index} | _] ->
        validation_error(Atom.to_string(kind), index, pos, "at most one #{kind} stage is allowed")

      _ ->
        :ok
    end
  end

  # --- filter ---

  defp apply_stage({:filter, ast, pos}, index, %{mode: :base} = ctx) do
    with :ok <- ensure_not_limited(ctx, "filter", index, pos),
         {:ok, pruned} <- Params.prune(ast, params(ctx)),
         {:ok, rewritten} <- ExistsRewriter.rewrite(pruned, base_builder_opts(ctx)),
         {:ok, dynamic_expr, joins} <- Builder.build(rewritten, base_builder_opts(ctx)) do
      {:ok, %{ctx | query: ctx.query |> Joins.apply(joins) |> where(^dynamic_expr)}}
    else
      {:error, message} when is_binary(message) ->
        {:error, stage_message("filter", index, message)}

      {:error, _} = error ->
        error
    end
  end

  defp apply_stage({:filter, ast, _pos}, index, %{mode: :derived} = ctx) do
    ctx = maybe_wrap(ctx)

    with {:ok, pruned} <- Params.prune(ast, params(ctx)),
         {:ok, substituted} <- Params.substitute(pruned, params(ctx)),
         {:ok, rewritten} <- rewrite_output_columns(substituted, ctx.cols),
         {:ok, dynamic_expr, _joins} <- Builder.build(rewritten, derived_builder_opts(ctx)) do
      {:ok, %{ctx | query: where(ctx.query, ^dynamic_expr)}}
    else
      {:error, message} when is_binary(message) ->
        {:error, stage_message("filter", index, message)}

      {:error, _} = error ->
        error
    end
  end

  # --- select ---

  defp apply_stage({:select, items, pos}, index, ctx) do
    ctx = maybe_wrap(ctx)

    with :ok <- ensure_not_limited(ctx, "select", index, pos),
         {:ok, cols, joins} <- build_columns(items, "select", index, ctx),
         :ok <- check_budget(cols, "select", index, pos),
         :ok <- check_unique_names(cols, "select", index) do
      cols = assign_keys(cols)
      select_map = Map.new(cols, &{&1.key, &1.dyn})

      query =
        ctx.query
        |> Joins.apply(joins)
        |> Ecto.Query.exclude(:select)
        |> select(^select_map)

      {:ok, derived_ctx(ctx, query, cols)}
    end
  end

  # --- group ---

  defp apply_stage({:group, breakouts, aggs, pos}, index, ctx) do
    ctx = maybe_wrap(ctx)

    with :ok <- ensure_not_limited(ctx, "group", index, pos),
         {:ok, breakout_cols, breakout_joins} <- build_columns(breakouts, "group", index, ctx),
         {:ok, agg_cols, agg_joins} <- build_agg_columns(aggs, index, ctx),
         cols = breakout_cols ++ agg_cols,
         :ok <- check_budget(cols, "group", index, pos),
         :ok <- check_unique_names(cols, "group", index) do
      cols = assign_keys(cols)
      select_map = Map.new(cols, &{&1.key, &1.dyn})
      breakout_dynamics = Enum.map(breakout_cols, & &1.dyn)

      query =
        ctx.query
        |> Joins.apply(breakout_joins ++ agg_joins)
        |> Ecto.Query.exclude(:select)
        |> then(fn query ->
          if breakout_dynamics == [], do: query, else: group_by(query, ^breakout_dynamics)
        end)
        |> select(^select_map)

      {:ok, derived_ctx(ctx, query, cols)}
    end
  end

  # --- sort ---

  defp apply_stage({:sort, keys, pos}, index, ctx) do
    ctx = maybe_wrap(ctx)

    with :ok <- ensure_not_limited(ctx, "sort", index, pos),
         {:ok, order, joins} <- build_sort_keys(keys, index, ctx) do
      query =
        ctx.query
        |> Joins.apply(joins)
        |> Ecto.Query.exclude(:order_by)
        |> order_by(^order)

      {:ok, %{ctx | query: query}}
    end
  end

  # --- limit / offset ---

  defp apply_stage({:limit, n, _pos}, _index, ctx) do
    {:ok, after_row_stage(%{ctx | query: limit(ctx.query, ^n)})}
  end

  defp apply_stage({:offset, n, _pos}, _index, ctx) do
    {:ok, after_row_stage(%{ctx | query: offset(ctx.query, ^n)})}
  end

  # After limit/offset, a later column-referencing stage must address this
  # level's output. Derived levels always carry a select, so they can wrap;
  # base levels cannot (no projection), so they flag `limited` and reject.
  defp after_row_stage(%{mode: :base} = ctx), do: %{ctx | limited: true}
  defp after_row_stage(%{mode: :derived} = ctx), do: %{ctx | pending_wrap: true}

  # --- Wrapping ---

  # Wraps the accumulated query in a subquery so the next stage addresses the
  # previous projection's output columns. The new level gets an identity
  # select over the positional keys, so it can itself be wrapped later (e.g.
  # group | filter | limit | sort).
  defp maybe_wrap(%{mode: :derived, pending_wrap: true} = ctx) do
    identity = Map.new(ctx.cols, fn col -> {col.key, dynamic([row], field(row, ^col.key))} end)
    query = from(row in subquery(ctx.query)) |> select(^identity)
    %{ctx | query: query, pending_wrap: false}
  end

  defp maybe_wrap(ctx), do: ctx

  defp derived_ctx(ctx, query, cols) do
    cols = Enum.map(cols, &Map.drop(&1, [:dyn, :pos]))

    %{
      ctx
      | mode: :derived,
        query: query,
        cols: cols,
        allowed: nil,
        pending_wrap: true,
        limited: false
    }
  end

  # --- Column building (select items / group breakouts) ---

  # Each item resolves to %{name, type, dyn, pos} plus join specs. Positioned
  # validation errors point at the offending identifier or alias.
  defp build_columns(items, stage, index, ctx) do
    Enum.reduce_while(items, {:ok, [], []}, fn item, {:ok, cols, joins} ->
      case build_column(item, stage, index, ctx) do
        {:ok, col, new_joins} -> {:cont, {:ok, [col | cols], joins ++ new_joins}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, cols, joins} -> {:ok, Enum.reverse(cols), joins}
      {:error, _} = error -> error
    end
  end

  defp build_column({:pcol, name, pos}, stage, index, ctx) do
    with {:ok, dyn, joins, type} <- resolve_column(name, pos, stage, index, ctx) do
      {:ok, %{name: name, type: type, dyn: dyn, pos: pos}, joins}
    end
  end

  defp build_column({:aliased, alias_name, alias_pos, func}, stage, index, ctx) do
    with {:ok, dyn, joins, type} <- resolve_function(func, stage, index, ctx) do
      {:ok, %{name: alias_name, type: type, dyn: dyn, pos: alias_pos}, joins}
    end
  end

  # Un-aliased function breakout: gets a derived, identifier-shaped name so
  # later stages can reference it (round_month(inserted_at) →
  # "round_month_inserted_at").
  defp build_column({:pfunc, fname, pos, args} = func, stage, index, ctx) do
    with {:ok, dyn, joins, type} <- resolve_function(func, stage, index, ctx) do
      name =
        [fname | for({:pcol, arg_name, _} <- args, do: String.replace(arg_name, ".", "_"))]
        |> Enum.join("_")

      {:ok, %{name: name, type: type, dyn: dyn, pos: pos}, joins}
    end
  end

  # --- Aggregations ---

  defp build_agg_columns(aggs, index, ctx) do
    Enum.reduce_while(aggs, {:ok, [], []}, fn agg, {:ok, cols, joins} ->
      case build_agg_column(agg, index, ctx) do
        {:ok, col, new_joins} -> {:cont, {:ok, [col | cols], joins ++ new_joins}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, cols, joins} -> {:ok, Enum.reverse(cols), joins}
      {:error, _} = error -> error
    end
  end

  defp build_agg_column({:agg, alias_name, alias_pos, "count", nil}, _index, _ctx) do
    col = %{name: alias_name, type: :integer, dyn: dynamic([row], count()), pos: alias_pos}
    {:ok, col, []}
  end

  defp build_agg_column({:agg, alias_name, alias_pos, fun, {:pcol, name, pos}}, index, ctx) do
    with {:ok, arg_dyn, joins, arg_type} <- resolve_column(name, pos, "group", index, ctx) do
      col = %{
        name: alias_name,
        type: agg_type(fun, arg_type),
        dyn: agg_dynamic(fun, arg_dyn),
        pos: alias_pos
      }

      {:ok, col, joins}
    end
  end

  defp agg_dynamic("count", expr), do: dynamic([row], count(^expr))
  defp agg_dynamic("count_distinct", expr), do: dynamic([row], count(^expr, :distinct))
  defp agg_dynamic("sum", expr), do: dynamic([row], sum(^expr))
  defp agg_dynamic("avg", expr), do: dynamic([row], avg(^expr))
  defp agg_dynamic("min", expr), do: dynamic([row], min(^expr))
  defp agg_dynamic("max", expr), do: dynamic([row], max(^expr))

  defp agg_type("count", _), do: :integer
  defp agg_type("count_distinct", _), do: :integer
  defp agg_type("sum", arg_type), do: arg_type
  defp agg_type("min", arg_type), do: arg_type
  defp agg_type("max", arg_type), do: arg_type
  defp agg_type("avg", _), do: nil

  # --- Sort keys ---

  defp build_sort_keys(keys, index, ctx) do
    Enum.reduce_while(keys, {:ok, [], []}, fn {:key, dir, name, pos}, {:ok, order, joins} ->
      case resolve_column(name, pos, "sort", index, ctx) do
        {:ok, dyn, new_joins, _type} -> {:cont, {:ok, [{dir, dyn} | order], joins ++ new_joins}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, order, joins} -> {:ok, Enum.reverse(order), joins}
      {:error, _} = error -> error
    end
  end

  # --- Column / function resolution ---

  # Resolves a column reference in the current context. Base context: full
  # identifier rules (allowlist, association paths with joins, JSONB paths);
  # plural associations are rejected — EXISTS semantics only make sense in
  # filters. Derived context: output columns of the previous projection.
  defp resolve_column(name, pos, stage, index, %{mode: :base} = ctx) do
    builder_opts = base_builder_opts(ctx)

    with :ok <- ensure_singular(name, pos, stage, index, ctx) do
      case Builder.expr({:identifier, name}, builder_opts) do
        {:ok, dyn, joins} ->
          {:ok, dyn, joins, Builder.type_of({:identifier, name}, builder_opts)}

        {:error, message} ->
          validation_error(stage, index, pos, message)
      end
    end
  end

  defp resolve_column(name, pos, stage, index, %{mode: :derived} = ctx) do
    case find_column(ctx.cols, name) do
      nil ->
        validation_error(stage, index, pos, unknown_column_message(name, ctx.cols))

      col ->
        {:ok, dynamic([row], field(row, ^col.key)), [], col.type}
    end
  end

  defp ensure_singular(name, pos, stage, index, ctx) do
    case Identifier.classify(name, classify_opts(ctx)) do
      :singular ->
        :ok

      {:plural, _binding, _kind, _aopts, _inner, _sub_opts} ->
        validation_error(
          stage,
          index,
          pos,
          "plural association path #{name} cannot be used in #{stage} — " <>
            "plural associations are only supported inside filter stages"
        )

      {:error, message} ->
        validation_error(stage, index, pos, message)
    end
  end

  defp classify_opts(%{allowed: allowed}) when is_list(allowed), do: [allowed_fields: allowed]
  defp classify_opts(_ctx), do: []

  # Function application (select alias / breakout). Arguments are validated
  # individually first so errors carry the inner token's position; the whole
  # expression is then evaluated through the shared Builder rules.
  defp resolve_function({:pfunc, _fname, fpos, args} = func, stage, index, ctx) do
    with :ok <- validate_function_args(args, stage, index, ctx) do
      case Builder.expr(function_ast(func, ctx), function_builder_opts(ctx)) do
        {:ok, dyn, joins} -> {:ok, dyn, joins, function_type(func, ctx)}
        {:error, message} -> validation_error(stage, index, fpos, message)
      end
    end
  end

  defp validate_function_args(args, stage, index, ctx) do
    Enum.reduce_while(args, :ok, fn
      {:pcol, name, pos}, :ok ->
        case resolve_column(name, pos, stage, index, ctx) do
          {:ok, _dyn, _joins, _type} -> {:cont, :ok}
          {:error, _} = error -> {:halt, error}
        end

      {:pfunc, _, _, _} = nested, :ok ->
        case resolve_function(nested, stage, index, ctx) do
          {:ok, _dyn, _joins, _type} -> {:cont, :ok}
          {:error, _} = error -> {:halt, error}
        end

      _literal, :ok ->
        {:cont, :ok}
    end)
  end

  # Converts pipe AST nodes ({:pcol, ...}, {:pfunc, ...}) to the Builder's
  # AST shapes. In the derived context column names are swapped for their
  # positional keys (already validated, so lookups cannot miss).
  defp function_ast({:pfunc, fname, _pos, args}, ctx),
    do: {:function, fname, Enum.map(args, &function_ast(&1, ctx))}

  defp function_ast({:pcol, name, _pos}, %{mode: :base}), do: {:identifier, name}

  defp function_ast({:pcol, name, _pos}, %{mode: :derived} = ctx) do
    {:identifier, Atom.to_string(find_column(ctx.cols, name).key)}
  end

  defp function_ast(literal, _ctx), do: literal

  # Temporal bucketing keeps the argument's type (DATE_TRUNC preserves it for
  # coercion purposes); other functions produce an unknown type.
  defp function_type({:pfunc, fname, _pos, [first | _]}, ctx) when fname in @round_functions do
    argument_type(first, ctx)
  end

  defp function_type(_func, _ctx), do: nil

  defp argument_type({:pcol, name, _pos}, %{mode: :base} = ctx),
    do: Builder.type_of({:identifier, name}, base_builder_opts(ctx))

  defp argument_type({:pcol, name, _pos}, %{mode: :derived} = ctx) do
    case find_column(ctx.cols, name) do
      nil -> nil
      col -> col.type
    end
  end

  defp argument_type(_arg, _ctx), do: nil

  # --- Derived-context filter rewriting ---

  # Rewrites every identifier in a filter AST (params already pruned and
  # substituted) to the positional key of the output column it names. Filter
  # ASTs carry no per-token positions, so unknown columns here produce plain
  # binary errors — the documented boundary of positioned validation errors.
  defp rewrite_output_columns(ast, cols) do
    {:ok, walk_rewrite(ast, cols)}
  catch
    {:unknown_column, name} -> {:error, unknown_column_message(name, cols)}
  end

  defp walk_rewrite({:identifier, name}, cols) do
    case find_column(cols, name) do
      nil -> throw({:unknown_column, name})
      col -> {:identifier, Atom.to_string(col.key)}
    end
  end

  defp walk_rewrite({:and, items}, cols), do: {:and, Enum.map(items, &walk_rewrite(&1, cols))}
  defp walk_rewrite({:or, items}, cols), do: {:or, Enum.map(items, &walk_rewrite(&1, cols))}
  defp walk_rewrite({:not, inner}, cols), do: {:not, walk_rewrite(inner, cols)}

  defp walk_rewrite({:op, op, left, right}, cols),
    do: {:op, op, walk_rewrite(left, cols), walk_rewrite(right, cols)}

  defp walk_rewrite({:between, target, low, high}, cols) do
    {:between, walk_rewrite(target, cols), walk_rewrite(low, cols), walk_rewrite(high, cols)}
  end

  defp walk_rewrite({:is_null, expr}, cols), do: {:is_null, walk_rewrite(expr, cols)}
  defp walk_rewrite({:is_not_null, expr}, cols), do: {:is_not_null, walk_rewrite(expr, cols)}

  defp walk_rewrite({:function, name, args}, cols),
    do: {:function, name, Enum.map(args, &walk_rewrite(&1, cols))}

  defp walk_rewrite({:list, items}, cols), do: {:list, Enum.map(items, &walk_rewrite(&1, cols))}
  defp walk_rewrite(other, _cols), do: other

  # --- Validation helpers ---

  defp check_unique_names(cols, stage, index) do
    cols
    |> Enum.reduce_while(MapSet.new(), fn col, seen ->
      if MapSet.member?(seen, col.name) do
        {:halt, {:duplicate, col}}
      else
        {:cont, MapSet.put(seen, col.name)}
      end
    end)
    |> case do
      {:duplicate, col} ->
        validation_error(stage, index, col.pos, "duplicate output column: #{col.name}")

      _seen ->
        :ok
    end
  end

  defp check_budget(cols, stage, index, pos) do
    if length(cols) > @max_columns do
      validation_error(
        stage,
        index,
        pos,
        "a stage may produce at most #{@max_columns} columns, got #{length(cols)}"
      )
    else
      :ok
    end
  end

  defp assign_keys(cols) do
    cols
    |> Enum.zip(@column_keys)
    |> Enum.map(fn {col, key} -> Map.put(col, :key, key) end)
  end

  defp ensure_not_limited(%{mode: :base, limited: true}, stage, index, pos) do
    validation_error(
      stage,
      index,
      pos,
      "#{stage} cannot follow limit/offset on an unprojected source — " <>
        "add a select or group stage before limit/offset"
    )
  end

  defp ensure_not_limited(_ctx, _stage, _index, _pos), do: :ok

  defp find_column(cols, name), do: Enum.find(cols, &(&1.name == name))

  defp unknown_column_message(name, cols) do
    "unknown column: #{name} (output columns: #{Enum.map_join(cols, ", ", & &1.name)})"
  end

  defp validation_error(stage, index, pos, message) do
    {:error,
     %ValidationError{
       message: message,
       line: pos && pos.line,
       column: pos && pos.column,
       byte_offset: pos && pos.offset,
       stage: stage,
       stage_index: index
     }}
  end

  defp stage_message(stage, index, message), do: "in #{stage} stage #{index}: #{message}"

  # --- Builder options ---

  defp params(ctx), do: Keyword.get(ctx.opts, :params, %{})

  defp base_builder_opts(ctx) do
    [source_binding: @source_binding]
    |> put_if(:allowed_fields, if(is_list(ctx.allowed), do: ctx.allowed))
    |> put_if(:literal_transform, Keyword.get(ctx.opts, :literal_transform))
    |> Keyword.put(:params, params(ctx))
  end

  defp derived_builder_opts(ctx) do
    [allowed_fields: Enum.map(ctx.cols, &{&1.key, &1.type})]
    |> put_if(:literal_transform, Keyword.get(ctx.opts, :literal_transform))
  end

  defp function_builder_opts(%{mode: :base} = ctx), do: base_builder_opts(ctx)
  defp function_builder_opts(%{mode: :derived} = ctx), do: derived_builder_opts(ctx)

  defp put_if(opts, _key, nil), do: opts
  defp put_if(opts, key, value), do: Keyword.put(opts, key, value)
end
