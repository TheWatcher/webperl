Overview                                                             {#overview}
========

The modules and classes discussed here are the result of an uneasy balance between
ease of use and features - the modules (with a couple of exceptions) are not unique,
and may provide fewer features than some alternatives. However, they all present
simple, concise interfaces that make them easy to use, in stark contrast to their
more featureful brethren.

At least I think they do. I might be biased, however.

Moreover, the intent behind this framework is to provide a simple base from which
to rapidly develop web applications, with as few rigid rules as possible - if you
need a more featureful module for something, you will probably be able to use it.

Basics
------

Much of what follows assumes that you are using the Application class as the
base of your webapp. It is important to note that this is not the only way in
which the classes and modules in the framework may be used, and it is likely
that you will find different ways of doing things, as is only Right and Proper.

The core feature underlying the operation of the webperl framework is the dynamic
loading of "blocks": your webapp should consist of one or more subclasses of the
Block class, usually stored in the cunningly named `blocks` directory (see the
[Structuring](@ref appstructure) document for more about the directory hierarchy).
Each subclass of Block should implement a piece of your webapp's functionality -
how much or how little is left entirely up to you. The subclasses are loaded by
the Modules class 'on demand', so the system does not attempt to load lots of
redundant functionality when started. You could implement your entire webapp in
a single block if you wanted, but unless it is very simple a lot of unused code
will be loaded each time a page is generated. Splitting your application up allows
for more logical compartmentalisation of features, and reduces interpreter
overhead.

If you are using the Application class as the base of your webapp, it will
perform all the framework setup process for you, and then load one of your
Block subclasses to generate the actual page content. Application looks at the
'block' parameter in the query string or POSTed data to determine which block
to load, and if the value in the `block` parameter is invalid or missing, a
default 'initial block' specified in the configuration is loaded instead. For
more about blocks, see the [Blocks](@ref blocks) documentation.

Once a block has been loaded, Application calls the block's page_display()
method and prints the returned string to stdout, typically sending it back to the
client web browser. What the block does in page_display is up to you: it could
put together a HTML/XHTML page and return it, sending the page back to the user,
or it could generate some other form of content and exit, bypassing the normal
behaviour of Application (you might want to do this if sending anything other
than HTML back to the user - xml, file data, etc).

Essentially, Application acts as a bootstrap, initialising the standard modules
and framework for you and then jumping into one of your blocks to do the actual
work of generating something to send back to the user. What happens when
Application hands execution over to your blocks is entirely up to you. See the
[Blocks](@ref blocks) documentation for information about what gets passed to
your block's constructor, and from there you can investigate the documentation
for the modules provided in the framework.

The Documentation
-----------------

The remainder of the documentation given here is split up into pages discussing
specific aspects of the library:

* [Blocks](@ref blocks) discusses the purpose, loading, and features of the
  Block class and subclasses you may with to implement in your application.
* [Structure](@ref structure) covers the suggested layout of files and directories.
* [Configuration](@ref config) discusses the core configuration file, and the
  optional settings table in the database.
* [Sessions](@ref sessions) introduces the session handling feature of the
  framework, and the various authentication schemes supported.
* [Quick start](@ref quickstart) is a very brief run-through of the steps needed
  to create a new webapp.

Finally, remember this is Perl - the instructions contained here, and in
the rest of the documentation, are not the only way to do it. If you find
that following the structure discussed in this documentation is limiting, go ahead
and try other ways - you'll undoubtedly be able to find many other ways of using
the framework that better suit your needs.

