# frozen_string_literal: true

class AddReference < ActiveRecord::Migration[5.1]
  def change
    add_reference(:comments, :user)
  end
end
