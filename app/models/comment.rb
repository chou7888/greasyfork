require 'memoist'

class Comment < ApplicationRecord
  extend Memoist
  include HasAttachments
  include SoftDeletable

  belongs_to :discussion
  # Optional because the user may no longer exist.
  belongs_to :poster, class_name: 'User', optional: true
  has_many :reports, as: :item, dependent: :destroy

  validates :text, presence: true
  validates :text_markup, inclusion: { in: %w[html markdown] }, presence: true

  delegate :script, to: :discussion

  strip_attributes only: :text

  def path(locale: nil)
    discussion_path = discussion.path(locale: locale)
    discussion_path += "#comment-#{id}" unless first_comment?
    discussion_path
  end

  def url(locale: nil)
    discussion_url = discussion.url(locale: locale)
    discussion_url += "#comment-#{id}" unless first_comment?
    discussion_url
  end

  before_destroy do
    discussion.destroy if first_comment?
  end

  after_soft_destroy do
    discussion.soft_destroy! if first_comment? && !discussion.soft_deleted?
  end

  after_commit do
    discussion.update_stats! unless discussion.destroyed? || discussion.soft_deleted?
  end

  after_destroy do
    Report.where(item: self).destroy_all
  end

  def send_notifications!
    satn = script_authors_to_notify

    satn.each do |author_user|
      ForumMailer.comment_on_script(author_user, self).deliver_later
    end

    # Don't double-notify.
    discussion.discussion_subscriptions.where.not(user: [poster] + satn).includes(:user).map(&:user).each do |user|
      ForumMailer.comment_on_subscribed(user, self).deliver_later
    end
  end

  def script_authors_to_notify
    return User.none unless script

    script
      .users
      .reject { |user| poster == user }
      .select { |author_user| author_user.author_email_notification_type_id == User::AUTHOR_NOTIFICATION_COMMENT || (author_user.author_email_notification_type_id == User::AUTHOR_NOTIFICATION_DISCUSSION && first_comment?) }
  end

  def notify_subscribers!; end

  def update_stats!
    update!(calculate_stats)
  end

  def assign_stats
    assign_attributes(calculate_stats)
  end

  def calculate_stats
    {
      first_comment: discussion.comments.order(:id).first == self,
    }
  end
end
