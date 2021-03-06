require "topological_inventory/orchestrator/metric_scaler"

describe TopologicalInventory::Orchestrator::MetricScaler do
  let(:instance) { described_class.new(nil, nil, logger) }
  let(:logger)   { Logger.new(StringIO.new).tap { |logger| allow(logger).to receive(:info) } }

  it "skips deployment configs that aren't fully configured" do
    deployment     = double("deployment", :metadata => double("metadata", :name => "deployment-#{rand(100..500)}", :annotations => {}))
    object_manager = double("TopologicalInventory::Orchestrator::ObjectManager", :get_deployment_configs => [deployment], :get_deployment_config => deployment)

    expect(TopologicalInventory::Orchestrator::ObjectManager).to receive(:new).and_return(object_manager)
    expect(Thread).to receive(:new).and_yield # Sorry, The use of doubles or partial doubles from rspec-mocks outside of the per-test lifecycle is not supported. (RSpec::Mocks::OutsideOfExampleError)

    watcher = described_class::Watcher.new(nil, deployment, deployment.metadata.name, logger)
    expect(watcher).not_to receive(:percent_usage_from_metrics)
    expect(described_class::Watcher).to receive(:new).with(nil, deployment, deployment.metadata.name, logger).and_return(watcher)

    instance.run_once
  end
end
