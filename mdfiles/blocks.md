Blocks                                                                 {#blocks}
======

The Block class serves as the base class for 'blocks' in your web application.
A 'block' is considered to be a discrete feature of your web application - you
will usually have a `Login.pm` block that handles logging users in and out, you
might have a `Core.pm` block that generates the front page and a few associated
pages. Essentially, each feature of your application will usually have one or
more blocks associated with it.

The Block class itself is quite simple: it provides a number of useful validation
functions, so that your code doesn't need to implement its own string and option
validation in most cases, it allows your application to log user actions if
needed, and it provides a stub implementation of the page_display() function
that all subclasses need to override.

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

When subclassing Block, you will need to provide your own implementation of
Block::page_display() - in most cases that's the only method you need to
worry about overriding, and the remaining methods in Block will generally
be usable as-is.
