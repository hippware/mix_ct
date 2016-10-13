# Adapted from mix-erlang-tasks by Alexei Sholik:
#
# The MIT License (MIT)
#
#Copyright (c) 2015 Alexei Sholik <alcosholik@gmail.com>
#
#Permission is hereby granted, free of charge, to any person obtaining a copy
#of this software and associated documentation files (the "Software"), to deal
#in the Software without restriction, including without limitation the rights
#to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
#copies of the Software, and to permit persons to whom the Software is
#furnished to do so, subject to the following conditions:
#
#The above copyright notice and this permission notice shall be included in
#all copies or substantial portions of the Software.
#
#THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
#IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
#FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
#AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
#LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
#OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
#THE SOFTWARE.

defmodule Mix.Tasks.Ct do
  use Mix.Task

  @moduledoc """
  Runs the Common Test suite for a project.

  This task compiles the application then runs all of the Common Test suites
  in the `test` directory.

  ## Command line options

    * `--suite`, `-s`       - comma separated list of suites to run
    * `--group`, `-g`       - comma separated list of groups to run
    * `--testcase`, `-t`    - comma separated list of test cases to run
    * `--config`, `-f`      - test config to use; default: test/test.config
    * `--log-dir`, `-l`     - change the output directory; default: _build/<ENV>/ct_logs
    * `--cover`, `-c`       - run cover report
  """
  @shortdoc "Runs a project's Common Test suite"
  @preferred_cli_env :test
  @recursive true

  @test_dir "test"

  @cover [output: "cover", tool: Mix.Tasks.Test.Cover]

  def run(args) do
    options = parse_options(args)
    project = Mix.Project.config

    # add test directory to compile paths and add
    # compiler options for test
    post_config = ct_post_config(project)
    modify_project_config(post_config)

    # make sure mix will let us run compile
    ensure_compile
    Mix.Task.run "compile"

    # start cover
    cover =
      if options[:cover] do
        compile_path = Mix.Project.compile_path(project)
        cover = Keyword.merge(@cover, project[:test_coverage] || [])
        cover[:tool].start(compile_path, cover)
      end

    # run the actual tests
    prepare(options)
    ct_opts = get_ct_opts(options)
    result = run_tests(ct_opts)

    cover && cover.()

    case result do
      :error -> Mix.raise "mix ct failed"
      :ok -> :ok
    end
  end

  defp parse_options(args) do
    {switches, _argv, _errors} =
      OptionParser.parse(args, [
        strict: [
          dir:      :string,
          suite:    :string,
          group:    :string,
          testcase: :string,
          log_dir:  :string,
          config:   :string,
          cover:    :boolean
        ],
        aliases: [
          d: :dir,
          s: :suite,
          g: :group,
          t: :testcase,
          l: :log_dir,
          f: :config,
          c: :cover
        ]
      ])

    log_dir = Keyword.get(switches, :log_dir, "_build/#{Mix.env}/ct_logs")

    %{suite: switches[:suite] |> list_param,
      group: switches[:group] |> list_param,
      testcase: switches[:testcase] |> list_param,
      config: switches[:config] |> list_param,
      log_dir: log_dir,
      cover: switches[:cover]}
  end

  defp list_param(nil), do: nil
  defp list_param(str) do
    str
    |> String.split(",")
    |> Enum.map(&String.to_charlist/1)
  end

  defp ct_post_config(existing_config) do
    compile_opts = [parse_transform: :cth_readable_transform]
    [erlc_paths: existing_config[:erlc_paths] ++ [@test_dir],
     erlc_options: maybe_add_test_define(existing_config[:erlc_options] ++ compile_opts)]
  end

  defp maybe_add_test_define(opts) do
    if Enum.member?(opts, {:d, :TEST}) do
      opts
    else
      [{:d, :TEST} | opts]
    end
  end

  defp modify_project_config(post_config) do
    %{name: name, file: file} = Mix.Project.pop
    Mix.ProjectStack.post_config(post_config)
    Mix.Project.push name, file
  end

  defp ensure_compile do
    # we have to reenable compile and all of its
    # child tasks (compile.erlang, compile.elixir, etc)
    Mix.Task.reenable("compile")
    Enum.each(compilers, &Mix.Task.reenable/1)
  end

  defp compilers do
    Mix.Task.all_modules
    |> Enum.map(&Mix.Task.task_name/1)
    |> Enum.filter(fn(t) -> match?("compile." <> _, t) end)
  end

  defp prepare(options) do
    File.mkdir_p!(options[:log_dir])

    suites = options[:suite] || all_suites
    Enum.each(suites, &copy_data_dir/1)
  end

  defp all_suites do
    @test_dir
    |> Path.join("*_SUITE.erl")
    |> Path.wildcard
    |> Enum.map(fn s -> s |> Path.rootname |> Path.basename end)
  end

  defp copy_data_dir(suite) do
    data_dir_name = "#{suite}_data"
    data_dir = Path.join(@test_dir, data_dir_name)
    dest_dir = Path.join(ebin_path, data_dir_name)

    case File.cp_r(data_dir, dest_dir) do
      {:ok, _} -> :ok
      {:error, :enoent, ^data_dir} -> :ok
      e -> Mix.raise("Error copying data dir for #{suite}: #{inspect(e)}")
    end
  end

  defp get_ct_opts(options) do
    base_ct_opts = [
      auto_compile: false,
      ct_hooks:     [:cth_readable_failonly, :cth_readable_shell],
      logdir:       options[:log_dir] |> String.to_charlist,
      config:       test_config(options[:config]) |> String.to_charlist,
      dir:          ebin_path |> String.to_charlist
    ]

    ct_opts =
      [:suite, :group, :testcase]
      |> Enum.reduce(base_ct_opts, fn n, acc -> ct_opt(n, options[n], acc) end)

    if is_nil(ct_opts[:suite]) do
      [{:dir, @test_dir |> String.to_charlist} | ct_opts]
    else
      ct_opts
    end
  end

  defp test_config(nil), do: @test_dir |> Path.join("test.config")
  defp test_config(str), do: str

  defp ebin_path, do: Mix.Project.app_path |> Path.join("ebin")

  defp ct_opt(_, nil, ct_opts), do: ct_opts
  defp ct_opt(opt, val, ct_opts), do: [{opt, val} | ct_opts]

  defp run_tests(opts) do
    case :ct.run_test(opts) do
      {_, 0, {_, _}} -> :ok
      _ -> :error
    end
  end
end
