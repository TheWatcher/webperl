Overview                                                             {#overview}
========

The modules and classes discussed here are the result of an uneasy balance between
ease of use and features - the modules (with a couple of exceptions) are not unique,
and may provide fewer features than some alternatives. However, they all present
simple, concise interfaces that make them easy to use, in stark contrast to their
more featureful brethren.

At least I think they do. I might be biased, here.

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
redundant functionality when started. If you are using the Application class as
the base of your webapp, it will automatically load one of the Block subclasses
using the value specified in the 'block' parameter in the query string or POSTed
data (if the value in the blocks parameter is invalid or missing, a default
'initial block' specified in the configuration is loaded instead). For more about
blocks, see the [Blocks](@ref blocks) documentation.


