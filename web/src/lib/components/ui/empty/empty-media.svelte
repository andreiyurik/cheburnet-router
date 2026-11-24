<script module>
	import { cn } from "$lib/utils.js";

	const EMPTY_MEDIA_VARIANTS = {
  "variant": {
    "default": "bg-transparent",
    "icon": "bg-muted text-foreground flex size-10 shrink-0 items-center justify-center rounded-lg [&_svg:not([class*='size-'])]:size-6"
  }
};
export const emptyMediaVariants = ({ variant = "default" } = {}) =>
  cn("mb-2 flex shrink-0 items-center justify-center [&_svg]:pointer-events-none [&_svg]:shrink-0", EMPTY_MEDIA_VARIANTS.variant[variant]);
</script>

<script>

	let {
		ref = $bindable(null),
		class: className,
		children,
		variant = "default",
		...restProps
	} = $props();
</script>

<div
	bind:this={ref}
	data-slot="empty-icon"
	data-variant={variant}
	class={cn(emptyMediaVariants({ variant }), className)}
	{...restProps}
>
	{@render children?.()}
</div>
