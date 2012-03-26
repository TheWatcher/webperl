Blocks                                                                 {#blocks}
======

The Block class serves as the base class for 'blocks' in your web application.
A 'block' is considered to be a discrete feature of your web application - you
will usually have a `Login.pm` block that handles logging users in and out, you
might have a `Core.pm` block that generates the front page and a few associated
pages. Essentially, each feature of your application will usually have one or
more blocks associated with it. How granular you wish to be is entirely up to
you - the system does not enforce any rules on this.

The Block class itself is quite simple: it provides a number of useful validation
functions, so that your code doesn't need to implement its own string and option
validation in most cases, it allows your application to log user actions if
needed, and it provides stub implementations of the page_display() and
block_display() functions, one or both of which all subclasses need to override.

Each subclass of Block gets a number of references to useful objects added to
it on creation, and methods in the subclass can access them from $self. Some
of the more important and useful ones are:

* `$self -> {"template"}` contains a reference to the application's instance
of Template.
* `$self -> {"settings"}` is the web application's settings object. See the
[Configuration](@ref config) documentation for more on this, but usually you will
need to use `$self -> {"settings"} -> {"database"} -> {somename}` to use the
database table name mapping feature, and the settings stored in the settings
table are loaded into `$self -> {"settings"} -> {"config"}` as key-value pairs.
* `$self -> {"module"}` is an instance of the Modules class, through which
you can load other blocks as needed, or even dynamically load any perl module
that has a `new()` constructor via Modules::load_module().
* `$self -> {"cgi"}` is the global CGI object (or CGI::Compress::Gzip if you
have that available). You can use it to pull values out of the POST/GET data,
and so on.
* `$self -> {"dbh"}` is a DBI object connected to the web application's
database, issue queries through this rather than creating a separate
connection if possible.
* `$self -> {"session"}` is a reference to the current SessionHandler object. See
the [Sessions](@ref sessions) documentation for more about this.

Each Block subclass also has access to a few values that can be useful:

* `$self -> {"args"}` is a string containing any arguments set in the block's
  row in the blocks table in the database. The format of this string is not
  enforced, and will vary from module to module.

When subclassing Block, you will need to provide your own implementation of
either Block::page_display() or Block::block_display() (or perhaps both!)
In most cases you will only need to implement one of them, and the remaining
methods in Block will generally be usable as-is. If your block is able to
generate a complete page, you should implement the page_display() method. If
your block is only intended to produce a fragment of a page, and be invoked
by other blocks as needed, you'll need to write a block_display() method
instead. Sometimes you may find that there could be two different 'views' of
your block - say that your system includes a calendar, and sometimes it will
be displayed as a small box in a page with other content, and sometimes
the user will want to look at a page that shows nothing but the calendar.
You can implement both page_dusplay() and block_display() for the block,
the latter dealing with the situation where the calendar is embedded in a
larger page, while the former handles the situation where the user is
looking at just the calendar.
