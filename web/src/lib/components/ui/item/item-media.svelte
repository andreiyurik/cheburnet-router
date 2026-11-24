<script module>
	import { cn } from "$lib/utils.js";

	const ITEM_MEDIA_VARIANTS = {
  "variant": {
    "default": "bg-transparent",
    "icon": "bg-muted size-8 rounded-sm border [&_svg:not([class*='size-'])]:size-4",
    "image": "size-10 overflow-hidden rounded-sm [&_img]:size-full [&_img]:object-cover"
  }
};
export const itemMediaVariants = ({ variant = "default" } = {}) =>
  cn("flex shrink-0 items-center justify-center gap-2 group-has-[[data-slot=item-description]]/item:translate-y-0.5 group-has-[[data-slot=item-description]]/item:self-start [&_svg]:pointer-events-none", ITEM_MEDIA_VARIANTS.variant[variant]);
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
	data-slot="item-media"
	data-variant={variant}
	class={cn(itemMediaVariants({ variant }), className)}
	{...restProps}
>
	{@render children?.()}
</div>
