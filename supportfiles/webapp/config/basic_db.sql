-- phpMyAdmin SQL Dump
-- version 3.4.9
-- http://www.phpmyadmin.net
--
-- Host: localhost
-- Generation Time: Dec 06, 2012 at 12:11 AM
-- Server version: 5.1.66
-- PHP Version: 5.4.6--pl0-gentoo

SET SQL_MODE="NO_AUTO_VALUE_ON_ZERO";
SET time_zone = "+00:00";


/*!40101 SET @OLD_CHARACTER_SET_CLIENT=@@CHARACTER_SET_CLIENT */;
/*!40101 SET @OLD_CHARACTER_SET_RESULTS=@@CHARACTER_SET_RESULTS */;
/*!40101 SET @OLD_COLLATION_CONNECTION=@@COLLATION_CONNECTION */;
/*!40101 SET NAMES utf8 */;

-- --------------------------------------------------------

--
-- Table structure for table `auth_methods`
--

CREATE TABLE IF NOT EXISTS `auth_methods` (
  `id` tinyint(3) unsigned NOT NULL AUTO_INCREMENT,
  `perl_module` varchar(100) NOT NULL COMMENT 'The name of the AuthMethod (no .pm extension)',
  `priority` tinyint(4) NOT NULL COMMENT 'The authentication method''s priority. -128 = max, 127 = min',
  `enabled` tinyint(1) NOT NULL COMMENT 'Is this auth method usable?',
  PRIMARY KEY (`id`)
) ENGINE=MyISAM  DEFAULT CHARSET=utf8 COMMENT='Stores the authentication methods supported by the system' AUTO_INCREMENT=2 ;

-- --------------------------------------------------------

--
-- Table structure for table `auth_methods_params`
--

CREATE TABLE IF NOT EXISTS `auth_methods_params` (
  `method_id` tinyint(4) NOT NULL COMMENT 'The id of the auth method',
  `name` varchar(40) NOT NULL COMMENT 'The parameter mame',
  `value` text NOT NULL COMMENT 'The value for the parameter',
  KEY `method_id` (`method_id`)
) ENGINE=MyISAM DEFAULT CHARSET=utf8 COMMENT='Stores the settings for each auth method';

-- --------------------------------------------------------

--
-- Table structure for table `blocks`
--

CREATE TABLE IF NOT EXISTS `blocks` (
  `id` smallint(5) unsigned NOT NULL AUTO_INCREMENT COMMENT 'Unique ID for this block entry',
  `name` varchar(32) NOT NULL,
  `module_id` smallint(5) unsigned NOT NULL COMMENT 'ID of the module implementing this block',
  `args` varchar(128) NOT NULL COMMENT 'Arguments passed verbatim to the block module',
  PRIMARY KEY (`id`),
  UNIQUE KEY `name` (`name`)
) ENGINE=MyISAM  DEFAULT CHARSET=utf8 COMMENT='web-accessible page modules' AUTO_INCREMENT=5 ;

-- --------------------------------------------------------

--
-- Table structure for table `log`
--

CREATE TABLE IF NOT EXISTS `log` (
  `id` int(10) unsigned NOT NULL AUTO_INCREMENT,
  `logtime` int(10) unsigned NOT NULL COMMENT 'The time the logged event happened at',
  `user_id` int(10) unsigned DEFAULT NULL COMMENT 'The id of the user who triggered the event, if any',
  `ipaddr` varchar(16) DEFAULT NULL COMMENT 'The IP address the event was triggered from',
  `logtype` varchar(64) NOT NULL COMMENT 'The event type',
  `logdata` text COMMENT 'Any data that might be appropriate to log for this event',
  PRIMARY KEY (`id`)
) ENGINE=MyISAM  DEFAULT CHARSET=utf8 COMMENT='Stores a log of events in the system.' AUTO_INCREMENT=1362 ;

-- --------------------------------------------------------

--
-- Table structure for table `messages_queue`
--

CREATE TABLE IF NOT EXISTS `messages_queue` (
  `id` int(10) unsigned NOT NULL AUTO_INCREMENT,
  `previous_id` int(10) unsigned DEFAULT NULL COMMENT 'Link to a previous message (for replies/followups/etc)',
  `created` int(10) unsigned NOT NULL COMMENT 'The unix timestamp of when this message was created',
  `creator_id` int(10) unsigned DEFAULT NULL COMMENT 'Who created this message (NULL = system)',
  `deleted` int(10) unsigned DEFAULT NULL COMMENT 'Timestamp of message deletion, marks deletion of /sending/ message.',
  `deleted_id` int(10) unsigned DEFAULT NULL COMMENT 'Who deleted the message?',
  `message_ident` varchar(128) COLLATE utf8_unicode_ci DEFAULT NULL COMMENT 'Generic identifier, may be used for message lookup after addition',
  `subject` varchar(255) COLLATE utf8_unicode_ci NOT NULL COMMENT 'The message subject',
  `body` text COLLATE utf8_unicode_ci NOT NULL COMMENT 'The message body',
  `format` enum('text','html') COLLATE utf8_unicode_ci NOT NULL DEFAULT 'text' COMMENT 'Message format, for possible extension',
  `send_after` int(10) unsigned DEFAULT NULL COMMENT 'Send message after this time (NULL = as soon as possible)',
  PRIMARY KEY (`id`),
  KEY `created` (`created`),
  KEY `deleted` (`deleted`),
  KEY `message_ident` (`message_ident`),
  KEY `previous_id` (`previous_id`)
) ENGINE=MyISAM  DEFAULT CHARSET=utf8 COLLATE=utf8_unicode_ci COMMENT='Stores messages to be sent through Message:: modules' AUTO_INCREMENT=8 ;

-- --------------------------------------------------------

--
-- Table structure for table `messages_recipients`
--

CREATE TABLE IF NOT EXISTS `messages_recipients` (
  `message_id` int(10) unsigned NOT NULL COMMENT 'ID of the message this is a recipient entry for',
  `recipient_id` int(10) unsigned NOT NULL COMMENT 'ID of the user sho should get the email',
  `viewed` int(10) unsigned DEFAULT NULL COMMENT 'When did the recipient view this message (if at all)',
  `deleted` int(10) unsigned DEFAULT NULL COMMENT 'When did the recipient mark their view as deleted (if at all)',
  KEY `email_id` (`message_id`),
  KEY `recipient_id` (`recipient_id`)
) ENGINE=MyISAM DEFAULT CHARSET=utf8 COMMENT='Stores the recipients of messages';

-- --------------------------------------------------------

--
-- Table structure for table `messages_sender`
--

CREATE TABLE IF NOT EXISTS `messages_sender` (
  `message_id` int(10) unsigned NOT NULL COMMENT 'ID of the message this is a sender record for',
  `sender_id` int(10) unsigned NOT NULL COMMENT 'ID of the user who sent the message',
  `deleted` int(10) unsigned NOT NULL COMMENT 'Has the sender deleted this message from their list (DOES NOT DELETE THE MESSAGE!)',
  KEY `message_id` (`message_id`),
  KEY `sender_id` (`sender_id`)
) ENGINE=MyISAM DEFAULT CHARSET=utf8 COMMENT='Stores the sender of each message, and sender-specific infor';

-- --------------------------------------------------------

--
-- Table structure for table `messages_transports`
--

CREATE TABLE IF NOT EXISTS `messages_transports` (
  `id` int(10) unsigned NOT NULL AUTO_INCREMENT,
  `name` varchar(24) CHARACTER SET utf8 COLLATE utf8_unicode_ci NOT NULL COMMENT 'The transport name',
  `description` varchar(255) CHARACTER SET utf8 COLLATE utf8_unicode_ci DEFAULT NULL COMMENT 'Human readable description (or langvar name)',
  `perl_module` varchar(255) CHARACTER SET utf8 COLLATE utf8_unicode_ci NOT NULL COMMENT 'The perl module implementing the message transport.',
  `enabled` tinyint(1) NOT NULL COMMENT 'Is the transport enabled?',
  PRIMARY KEY (`id`)
) ENGINE=MyISAM  DEFAULT CHARSET=utf8 COMMENT='Stores the list of modules that provide message delivery' AUTO_INCREMENT=3 ;

-- --------------------------------------------------------

--
-- Table structure for table `messages_transports_status`
--

CREATE TABLE IF NOT EXISTS `messages_transports_status` (
  `id` int(10) unsigned NOT NULL AUTO_INCREMENT,
  `message_id` int(10) unsigned NOT NULL COMMENT 'The ID of the message this is a transport entry for',
  `transport_id` int(10) unsigned NOT NULL COMMENT 'The ID of the transport',
  `status_time` int(10) unsigned NOT NULL COMMENT 'The time the status was changed',
  `status` enum('pending','sent','failed') CHARACTER SET utf8 COLLATE utf8_unicode_ci NOT NULL DEFAULT 'pending' COMMENT 'The transport status',
  `status_message` text COMMENT 'human-readable status message (usually error messages)',
  PRIMARY KEY (`id`),
  KEY `message_id` (`message_id`),
  KEY `transport_id` (`transport_id`),
  KEY `status` (`status`)
) ENGINE=MyISAM  DEFAULT CHARSET=utf8 COMMENT='Stores transport status information for messages' AUTO_INCREMENT=15 ;

-- --------------------------------------------------------

--
-- Table structure for table `messages_transports_userctrl`
--

CREATE TABLE IF NOT EXISTS `messages_transports_userctrl` (
  `transport_id` int(10) unsigned NOT NULL COMMENT 'ID of the transport the user has set a control on',
  `user_id` int(10) unsigned NOT NULL COMMENT 'User setting the control',
  `enabled` tinyint(1) unsigned NOT NULL DEFAULT '1' COMMENT 'contact the user through this transport?',
  KEY `transport_id` (`transport_id`),
  KEY `user_id` (`user_id`),
  KEY `transport_user` (`transport_id`,`user_id`)
) ENGINE=MyISAM DEFAULT CHARSET=utf8 COMMENT='Allows users to explicitly enable, or disable, specific mess';

-- --------------------------------------------------------

--
-- Table structure for table `modules`
--

CREATE TABLE IF NOT EXISTS `modules` (
  `module_id` smallint(5) unsigned NOT NULL AUTO_INCREMENT COMMENT 'Unique module id',
  `name` varchar(80) NOT NULL COMMENT 'Short name for the module',
  `perl_module` varchar(128) NOT NULL COMMENT 'Name of the perl module in blocks/ (no .pm extension!)',
  `active` tinyint(1) unsigned NOT NULL COMMENT 'Is this module enabled?',
  PRIMARY KEY (`module_id`)
) ENGINE=MyISAM  DEFAULT CHARSET=utf8 COMMENT='Available site modules, perl module names, and status' AUTO_INCREMENT=5 ;

-- --------------------------------------------------------

--
-- Table structure for table `sessions`
--

CREATE TABLE IF NOT EXISTS `sessions` (
  `session_id` char(32) NOT NULL,
  `session_user_id` int(10) unsigned NOT NULL,
  `session_start` int(11) unsigned NOT NULL,
  `session_time` int(11) unsigned NOT NULL,
  `session_ip` varchar(40) NOT NULL,
  `session_autologin` tinyint(1) unsigned NOT NULL,
  PRIMARY KEY (`session_id`),
  KEY `session_time` (`session_time`),
  KEY `session_user_id` (`session_user_id`)
) ENGINE=MyISAM DEFAULT CHARSET=utf8 COMMENT='Website sessions';

-- --------------------------------------------------------

--
-- Table structure for table `session_keys`
--

CREATE TABLE IF NOT EXISTS `session_keys` (
  `key_id` char(32) COLLATE utf8_bin NOT NULL DEFAULT '',
  `user_id` int(10) unsigned NOT NULL DEFAULT '0',
  `last_ip` varchar(40) COLLATE utf8_bin NOT NULL DEFAULT '',
  `last_login` int(11) unsigned NOT NULL DEFAULT '0',
  PRIMARY KEY (`key_id`,`user_id`),
  KEY `last_login` (`last_login`)
) ENGINE=MyISAM DEFAULT CHARSET=utf8 COLLATE=utf8_bin COMMENT='Autologin keys';

-- --------------------------------------------------------

--
-- Table structure for table `session_variables`
--

CREATE TABLE IF NOT EXISTS `session_variables` (
  `session_id` char(32) NOT NULL,
  `var_name` varchar(80) NOT NULL,
  `var_value` text NOT NULL,
  KEY `session_id` (`session_id`),
  KEY `sess_name_map` (`session_id`,`var_name`)
) ENGINE=MyISAM DEFAULT CHARSET=utf8 COMMENT='Session-related variables';

-- --------------------------------------------------------

--
-- Table structure for table `settings`
--

CREATE TABLE IF NOT EXISTS `settings` (
  `name` varchar(255) COLLATE utf8_unicode_ci NOT NULL,
  `value` text COLLATE utf8_unicode_ci NOT NULL,
  PRIMARY KEY (`name`)
) ENGINE=MyISAM DEFAULT CHARSET=utf8 COLLATE=utf8_unicode_ci COMMENT='Site settings';


INSERT INTO `settings` (`name`, `value`) VALUES
('base', '/path/to/your/webapp'),
('scriptpath', '/'),
('cookie_name', 'webappname'),
('cookie_path', '/'),
('cookie_domain', ''),
('cookie_secure', '0'),
('default_style', 'default'),
('logfile', ''),
('default_block', '1'),
('Auth:allow_autologin', '1'),
('Auth:max_autologin_time', '30'),
('Auth:ip_check', '4'),
('Auth:session_length', '3600'),
('Auth:session_gc', '0'),
('Auth:unique_id', '1'),
('Session:lastgc', '0'),
('Core:envelope_address', 'your@email.addy'),
('Log:all_the_things', '1'),
('timefmt', '%d %b %Y %H:%M:%S %Z'),
('datefmt', '%d %b %Y'),
('Core:admin_email', 'admin@email.addy'),
('Message::Transport::Email::smtp_host', 'localhost'),
('Message::Transport::Email::smtp_port', '25');

-- --------------------------------------------------------

--
-- Table structure for table `users`
--

CREATE TABLE IF NOT EXISTS `users` (
  `user_id` int(10) unsigned NOT NULL AUTO_INCREMENT,
  `user_auth` tinyint(3) unsigned DEFAULT NULL COMMENT 'Id of the user''s auth method',
  `user_type` tinyint(3) unsigned DEFAULT '0' COMMENT 'The user type, 0 = normal, 3 = admin',
  `username` varchar(32) NOT NULL,
  `firstname` varchar(32) DEFAULT NULL,
  `surname` varchar(32) DEFAULT NULL,
  `password` char(59) DEFAULT NULL,
  `email` varchar(255) CHARACTER SET utf8 COLLATE utf8_unicode_ci DEFAULT NULL COMMENT 'User''s email address',
  `created` int(10) unsigned NOT NULL COMMENT 'The unix time at which this user was created',
  `activated` int(10) unsigned DEFAULT NULL COMMENT 'Is the user account active, and if so when was it activated?',
  `act_code` varchar(64) DEFAULT NULL COMMENT 'Activation code the user must provide when activating their account',
  `last_login` int(10) unsigned NOT NULL COMMENT 'The unix time of th euser''s last login',
  PRIMARY KEY (`user_id`),
  UNIQUE KEY `username` (`username`),
  KEY `email` (`email`)
) ENGINE=MyISAM  DEFAULT CHARSET=utf8 COMMENT='Stores the local user data for each user in the system' AUTO_INCREMENT=19 ;

/*!40101 SET CHARACTER_SET_CLIENT=@OLD_CHARACTER_SET_CLIENT */;
/*!40101 SET CHARACTER_SET_RESULTS=@OLD_CHARACTER_SET_RESULTS */;
/*!40101 SET COLLATION_CONNECTION=@OLD_COLLATION_CONNECTION */;
