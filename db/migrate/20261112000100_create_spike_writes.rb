class CreateSpikeWrites < ActiveRecord::Migration[8.1]
  def change
    create_table :spike_writes, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.string :body
      t.timestamps
    end
  end
end
