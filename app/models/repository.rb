# frozen_string_literal: true

class Repository < RepositoryBase
  include SearchableModel
  include SearchableByNameModel
  include RepositoryImportParser

  enum permission_level: Extends::SHARED_INVENTORIES_PERMISSION_LEVELS

  has_many :report_elements, inverse_of: :repository, dependent: :destroy
  has_many :team_repositories, inverse_of: :repository, dependent: :destroy
  has_many :teams_shared_with, through: :team_repositories, source: :team
  has_many :repository_snapshots,
           class_name: 'RepositorySnapshot',
           foreign_key: :parent_id,
           inverse_of: :original_repository

  before_save :sync_name_with_snapshots, if: :name_changed?

  validates :name,
            presence: true,
            uniqueness: { scope: :team_id, case_sensitive: false },
            length: { maximum: Constants::NAME_MAX_LENGTH }

  scope :accessible_by_teams, lambda { |teams|
    left_outer_joins(:team_repositories)
      .where('repositories.team_id IN (?) '\
             'OR team_repositories.team_id IN (?) '\
             'OR repositories.permission_level = ? '\
             'OR repositories.permission_level = ? ',
             teams,
             teams,
             Extends::SHARED_INVENTORIES_PERMISSION_LEVELS[:shared_read],
             Extends::SHARED_INVENTORIES_PERMISSION_LEVELS[:shared_write])
      .distinct
  }

  scope :used_on_task_but_unshared, lambda { |task, team|
    where(id: task.repository_rows
      .select(:repository_id))
      .where.not(id: accessible_by_teams(team.id).select(:id)).distinct
  }

  def self.within_global_limits?
    return true unless Rails.configuration.x.global_repositories_limit.positive?

    count < Rails.configuration.x.global_repositories_limit
  end

  def self.within_team_limits?(team)
    return true unless Rails.configuration.x.team_repositories_limit.positive?

    team.repositories.count < Rails.configuration.x.team_repositories_limit
  end

  def self.search(
    user,
    query = nil,
    page = 1,
    repository = nil,
    options = {}
  )
    repositories = repository&.id || Repository.accessible_by_teams(user.teams.pluck(:id)).pluck(:id)

    readable_rows = RepositoryRow.joins(:repository).where(repository_id: repositories)

    matched_by_user = readable_rows.joins(:created_by).where_attributes_like('users.full_name', query, options)

    repository_row_matches =
      readable_rows.where_attributes_like(['repository_rows.name', 'repository_rows.id'], query, options)

    repository_rows = readable_rows.where(id: repository_row_matches)
    repository_rows = repository_rows.or(readable_rows.where(id: matched_by_user))

    Extends::REPOSITORY_EXTRA_SEARCH_ATTR.each do |field, include_hash|
      custom_cell_matches = readable_rows.joins(repository_cells: include_hash)
                                         .where_attributes_like(field, query, options)
      repository_rows = repository_rows.or(readable_rows.where(id: custom_cell_matches))
    end

    # Show all results if needed
    if page == Constants::SEARCH_NO_LIMIT
      repository_rows.select('repositories.id AS id, COUNT(DISTINCT repository_rows.id) AS counter')
                     .group('repositories.id')
    else
      repository_rows.limit(Constants::SEARCH_LIMIT)
                     .offset((page - 1) * Constants::SEARCH_LIMIT)
    end
  end

  def default_columns_count
    Constants::REPOSITORY_TABLE_DEFAULT_STATE['length']
  end

  def i_shared?(team)
    shared_with_anybody? && self.team == team
  end

  def shared_with_anybody?
    (!not_shared? || team_repositories.any?)
  end

  def shared_with?(team)
    return false if self.team == team

    !not_shared? || private_shared_with?(team)
  end

  def shared_with_write?(team)
    return false if self.team == team

    shared_write? || private_shared_with_write?(team)
  end

  def shared_with_read?(team)
    return false if self.team == team

    shared_read? || team_repositories.where(team: team, permission_level: :shared_read).any?
  end

  def private_shared_with?(team)
    team_repositories.where(team: team).any?
  end

  def private_shared_with_write?(team)
    team_repositories.where(team: team, permission_level: :shared_write).any?
  end

  def self.viewable_by_user(_user, teams)
    where(team: teams)
  end

  def self.name_like(query)
    where('repositories.name ILIKE ?', "%#{query}%")
  end

  def importable_repository_fields
    fields = {}
    # First and foremost add record name
    fields['-1'] = I18n.t('repositories.default_column')
    # Add all other custom columns
    repository_columns.order(:created_at).each do |rc|
      next unless rc.importable?

      fields[rc.id] = rc.name
    end
    fields
  end

  def copy(created_by, name)
    new_repo = nil

    begin
      Repository.transaction do
        # Clone the repository object
        new_repo = dup
        new_repo.created_by = created_by
        new_repo.name = name
        new_repo.save!

        # Clone columns (only if new_repo was saved)
        repository_columns.find_each do |col|
          new_col = col.dup
          new_col.repository = new_repo
          new_col.created_by = created_by
          new_col.save!
        end
      end
    rescue ActiveRecord::RecordInvalid
      return false
    end

    # If everything is okay, return new_repo
    Activities::CreateActivityService
      .call(activity_type: :copy_inventory,
            owner: created_by,
            subject: new_repo,
            team: new_repo.team,
            message_items: { repository_new: new_repo.id, repository_original: id })

    new_repo
  end

  def cell_preload_includes
    cell_includes = []
    repository_columns.pluck(:data_type).each do |data_type|
      cell_includes << data_type.constantize::PRELOAD_INCLUDE
    end
    cell_includes
  end

  def import_records(sheet, mappings, user)
    importer = RepositoryImportParser::Importer.new(sheet, mappings, user, self)
    importer.run
  end

  def provision_snapshot(my_module, created_by = nil)
    created_by ||= self.created_by
    repository_snapshot = dup.becomes(RepositorySnapshot)
    repository_snapshot.assign_attributes(type: RepositorySnapshot.name,
                                          original_repository: self,
                                          my_module: my_module,
                                          created_by: created_by)
    repository_snapshot.provisioning!
    repository_snapshot.reload
    RepositorySnapshotProvisioningJob.perform_later(repository_snapshot)
    repository_snapshot
  end

  private

  def sync_name_with_snapshots
    repository_snapshots.update(name: name)
  end

  def assigned_rows(my_module)
    repository_rows.joins(:my_module_repository_rows).where(my_module_repository_rows: { my_module_id: my_module.id })
  end
end
