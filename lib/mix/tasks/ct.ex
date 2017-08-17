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

  @switches [
    dir:      :string,
    suite:    :string,
    group:    :string,
    testcase: :string,
    log_dir:  :string,
    config:   :string,
    cover:    :boolean
  ]

  @aliases [
    d: :dir,
    s: :suite,
    g: :group,
    t: :testcase,
    l: :log_dir,
    f: :config,
    c: :cover
  ]

  @default_cover_opts [output: "cover", tool: Mix.Tasks.Test.Cover]
  @default_opts [log_dir: "_build/#{Mix.env}/ct_logs", dir: "test"]

  def run(args) do
    project = Mix.Project.config
    options = parse_options(args, project)

    # add test directory to compile paths and add
    # compiler options for test
    post_config = ct_post_config(project, options)
    modify_project_config(post_config)

    Mix.Tasks.Compile.run(args)

    # start cover
    cover =
      if options[:cover] do
        compile_path = Mix.Project.compile_path(project)
        cover =
          Keyword.merge(@default_cover_opts, project[:test_coverage] || [])
        cover[:tool].start(compile_path, cover)
      end

    # run the actual tests
    suites = get_suites(options)
    if length(suites) > 0 do
      prepare(suites, options)

      result =
        options
        |> get_ct_opts()
        |> run_tests()

      cover && cover.()

      case result do
        {:error, :failed_tests} -> Mix.raise "mix ct failed"
        {:error, other} -> Mix.raise "mix ct failed: #{inspect other}"
        :ok -> :ok
      end
    else
      :ok
    end
  end

  defp parse_options(args, project) do
    {switches, _argv, _errors} =
      OptionParser.parse(args, [strict: @switches, aliases: @aliases])

    project_opts = project[:eunit] || []

    @default_opts
    |> Keyword.merge(project_opts)
    |> Keyword.merge(switches)
    |> Keyword.update(:suite, nil, &list_param/1)
    |> Keyword.update(:group, nil, &list_param/1)
    |> Keyword.update(:testcase, nil, &list_param/1)
    |> Keyword.update(:config, nil, &list_param/1)
    |> Keyword.take(Keyword.keys(@switches))
  end

  defp list_param(nil), do: nil
  defp list_param(list) when is_list(list) do
    Enum.map(list, &String.to_charlist/1)
  end
  defp list_param(str) do
    str
    |> String.split(",")
    |> Enum.map(&String.to_charlist/1)
  end

  defp ct_post_config(project, options) do
    compile_opts = [parse_transform: :cth_readable_transform]
    [erlc_paths: project[:erlc_paths] ++ [options[:dir]],
     erlc_options: maybe_add_test_define(project[:erlc_options] ++ compile_opts)]
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

  defp get_suites(options), do: options[:suite] || all_suites(options[:dir])

  defp all_suites(test_dir) do
    test_dir
    |> Path.join("*_SUITE.erl")
    |> Path.wildcard
    |> Enum.map(fn s -> s |> Path.rootname |> Path.basename end)
  end

  defp prepare(suites, options) do
    make_log_dir(options[:log_dir])
    copy_data_dirs(suites, options[:dir])
  end

  defp make_log_dir(log_dir) do
    case File.mkdir_p(log_dir) do
      :ok -> :ok
      {:error, error} ->
        Mix.raise(
          "Error creating log dir #{log_dir} from #{System.cwd}: " <>
          inspect(error)
        )
    end
  end

  defp copy_data_dirs(suites, test_dir) do
    Enum.each(suites, &copy_data_dir(&1, test_dir))
  end

  defp copy_data_dir(suite, test_dir) do
    data_dir_name = "#{suite}_data"
    data_dir = Path.join(test_dir, data_dir_name)
    dest_dir = Path.join(ebin_path(), data_dir_name)

    case File.cp_r(data_dir, dest_dir) do
      {:ok, _} -> :ok
      {:error, :enoent, ^data_dir} -> :ok
      e -> Mix.raise("Error copying data dir for #{suite}: #{inspect(e)}")
    end
  end

  defp get_ct_opts(options) do
    test_dir = options[:dir]
    base_ct_opts = [
      auto_compile: false,
      ct_hooks:     [:cth_readable_failonly, :cth_readable_shell],
      logdir:       options[:log_dir] |> String.to_charlist,
      config:       test_config(options[:config], test_dir) |> String.to_charlist,
      dir:          ebin_path() |> String.to_charlist
    ]

    ct_opts =
      [:suite, :group, :testcase]
      |> Enum.reduce(base_ct_opts, fn n, acc -> ct_opt(n, options[n], acc) end)

    if is_nil(ct_opts[:suite]) do
      [{:dir, test_dir |> String.to_charlist} | ct_opts]
    else
      ct_opts
    end
  end

  defp test_config(nil, test_dir), do: test_dir |> Path.join("test.config")
  defp test_config(str, _), do: str

  defp ebin_path, do: Mix.Project.app_path |> Path.join("ebin")

  defp ct_opt(_, nil, ct_opts), do: ct_opts
  defp ct_opt(opt, val, ct_opts), do: [{opt, val} | ct_opts]

  defp run_tests(opts) do
    case :ct.run_test(opts) do
      {_, 0, {_, _}} -> :ok
      {_, _, {_, _}} -> {:error, :failed_tests}
      {:error, e} -> {:error, e}
    end
  end
end
